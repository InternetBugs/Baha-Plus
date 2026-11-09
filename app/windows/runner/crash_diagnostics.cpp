#include "crash_diagnostics.h"

#if defined(_DEBUG)

#include <windows.h>
#include <dbghelp.h>

#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <cwchar>

namespace {
constexpr size_t kMaxFrames = 32;
constexpr size_t kMaxPathCharacters = 4096;
constexpr DWORD kLocalSymbolOptions =
    SYMOPT_DEFERRED_LOADS | SYMOPT_UNDNAME | SYMOPT_FAIL_CRITICAL_ERRORS |
    SYMOPT_NO_PROMPTS | SYMOPT_IGNORE_NT_SYMPATH | SYMOPT_IGNORE_CVREC |
    SYMOPT_DISABLE_SYMSRV_AUTODETECT;

// These resources intentionally live until process termination: a fault may
// happen during engine, plugin, or static destruction after wWinMain returns.
HANDLE stderr_handle = INVALID_HANDLE_VALUE;
HANDLE symbol_process = nullptr;
bool symbols_ready = false;
volatile LONG installed = 0;
volatile LONG logging_exception = 0;
LPTOP_LEVEL_EXCEPTION_FILTER previous_filter = nullptr;

void WriteLine(const char* format, ...) {
  char line[2048] = {};
  va_list arguments;
  va_start(arguments, format);
  _vsnprintf_s(line, sizeof(line), _TRUNCATE, format, arguments);
  va_end(arguments);
  const auto length = static_cast<DWORD>(std::strlen(line));
  DWORD written = 0;
  if (stderr_handle == nullptr || stderr_handle == INVALID_HANDLE_VALUE ||
      !WriteFile(stderr_handle, line, length, &written, nullptr)) {
    OutputDebugStringA(line);
  }
}

bool LocalExecutableDirectory(wchar_t* path, DWORD capacity) {
  const auto length = GetModuleFileNameW(nullptr, path, capacity);
  if (length == 0 || length >= capacity || length < 3 || path[1] != L':' ||
      path[2] != L'\\') {
    return false;
  }
  const wchar_t root[] = {path[0], L':', L'\\', L'\0'};
  const auto drive = GetDriveTypeW(root);
  if (drive != DRIVE_FIXED && drive != DRIVE_REMOVABLE && drive != DRIVE_RAMDISK) {
    return false;
  }
  auto* separator = std::wcsrchr(path, L'\\');
  if (separator == nullptr) {
    return false;
  }
  separator[1] = L'\0';
  return true;
}

void WriteFrame(size_t index, DWORD64 address) {
  MEMORY_BASIC_INFORMATION memory = {};
  DWORD64 module_base = 0;
  char module_path[kMaxPathCharacters] = {};
  const char* module_name = "unknown";
  if (VirtualQuery(reinterpret_cast<LPCVOID>(static_cast<uintptr_t>(address)),
                   &memory, sizeof(memory)) != 0 &&
      memory.Type == MEM_IMAGE) {
    module_base =
        static_cast<DWORD64>(reinterpret_cast<uintptr_t>(memory.AllocationBase));
    const auto length = GetModuleFileNameA(
        static_cast<HMODULE>(memory.AllocationBase), module_path,
        static_cast<DWORD>(sizeof(module_path)));
    if (length != 0 && length < sizeof(module_path)) {
      const auto* separator = std::strrchr(module_path, '\\');
      module_name = separator ? separator + 1 : module_path;
    }
  }

  alignas(SYMBOL_INFO) unsigned char symbol_buffer[sizeof(SYMBOL_INFO) + 512] = {};
  auto* symbol = reinterpret_cast<SYMBOL_INFO*>(symbol_buffer);
  symbol->SizeOfStruct = sizeof(SYMBOL_INFO);
  symbol->MaxNameLen = 512;
  DWORD64 displacement = 0;
  if (symbols_ready &&
      SymFromAddr(symbol_process, address, &displacement, symbol)) {
    // Log names only, never symbol paths, locals, stack memory, or arguments.
    const auto length = symbol->NameLen < 511 ? symbol->NameLen : 511;
    for (ULONG i = 0; i < length; ++i) {
      if (static_cast<unsigned char>(symbol->Name[i]) < 0x20) {
        symbol->Name[i] = '?';
      }
    }
    symbol->Name[length] = '\0';
    WriteLine(
        "[BAHA_NATIVE_CRASH] frame=%02llu pc=0x%llX %s+0x%llX %s+0x%llX\n",
        static_cast<unsigned long long>(index),
        static_cast<unsigned long long>(address), module_name,
        static_cast<unsigned long long>(address - module_base), symbol->Name,
        static_cast<unsigned long long>(displacement));
  } else {
    WriteLine("[BAHA_NATIVE_CRASH] frame=%02llu pc=0x%llX %s+0x%llX\n",
              static_cast<unsigned long long>(index),
              static_cast<unsigned long long>(address), module_name,
              static_cast<unsigned long long>(address - module_base));
  }
}

void WriteExceptionStack(EXCEPTION_POINTERS* exception) {
  if (exception == nullptr || exception->ExceptionRecord == nullptr) {
    WriteLine("[BAHA_NATIVE_CRASH] missing-exception-record\n");
    return;
  }
  const auto address = static_cast<DWORD64>(
      reinterpret_cast<uintptr_t>(exception->ExceptionRecord->ExceptionAddress));
  WriteLine("[BAHA_NATIVE_CRASH] unhandled code=0x%08lX thread=%lu pc=0x%llX\n",
            exception->ExceptionRecord->ExceptionCode, GetCurrentThreadId(),
            static_cast<unsigned long long>(address));

  const auto old_options = SymGetOptions();
  // Limit all lookups to the explicit local directory, ignoring environment
  // symbol paths and embedded PDB paths. Restore other components' options.
  SymSetOptions(kLocalSymbolOptions);
  __try {
    if (symbols_ready) {
      SymRefreshModuleList(symbol_process);
    }
    DWORD64 addresses[kMaxFrames] = {address};
    size_t count = address == 0 ? 0 : 1;
    if (exception->ContextRecord != nullptr && symbols_ready) {
      // StackWalk64 mutates its context. Preserve the original for the filter
      // that was installed before this diagnostic handler.
      CONTEXT context = *exception->ContextRecord;
      STACKFRAME64 frame = {};
      DWORD machine = 0;
#if defined(_M_X64)
      machine = IMAGE_FILE_MACHINE_AMD64;
      frame.AddrPC.Offset = context.Rip;
      frame.AddrFrame.Offset = context.Rbp;
      frame.AddrStack.Offset = context.Rsp;
#elif defined(_M_IX86)
      machine = IMAGE_FILE_MACHINE_I386;
      frame.AddrPC.Offset = context.Eip;
      frame.AddrFrame.Offset = context.Ebp;
      frame.AddrStack.Offset = context.Esp;
#elif defined(_M_ARM64)
      machine = IMAGE_FILE_MACHINE_ARM64;
      frame.AddrPC.Offset = context.Pc;
      frame.AddrFrame.Offset = context.Fp;
      frame.AddrStack.Offset = context.Sp;
#endif
      frame.AddrPC.Mode = AddrModeFlat;
      frame.AddrFrame.Mode = AddrModeFlat;
      frame.AddrStack.Mode = AddrModeFlat;
      auto last_address = frame.AddrPC.Offset;
      auto last_stack = frame.AddrStack.Offset;
      for (size_t attempt = 0;
           machine != 0 && count < kMaxFrames && attempt < kMaxFrames * 2;
           ++attempt) {
        if (!StackWalk64(machine, symbol_process, GetCurrentThread(), &frame,
                         &context, nullptr, SymFunctionTableAccess64,
                         SymGetModuleBase64, nullptr) ||
            frame.AddrPC.Offset == 0) {
          break;
        }
        if (frame.AddrPC.Offset == last_address &&
            frame.AddrStack.Offset == last_stack) {
          // The first call may return the faulting frame already recorded.
          if (attempt == 0) {
            continue;
          }
          break;
        }
        addresses[count++] = frame.AddrPC.Offset;
        last_address = frame.AddrPC.Offset;
        last_stack = frame.AddrStack.Offset;
      }
    }
    for (size_t index = 0; index < count; ++index) {
      WriteFrame(index, addresses[index]);
    }
    WriteLine("[BAHA_NATIVE_CRASH] end frames=%llu\n",
              static_cast<unsigned long long>(count));
  } __finally {
    SymSetOptions(old_options);
  }
}

LONG WINAPI LogUnhandledException(EXCEPTION_POINTERS* exception) {
  if (InterlockedCompareExchange(&logging_exception, 1, 0) == 0) {
    __try {
      WriteExceptionStack(exception);
    } __except (EXCEPTION_EXECUTE_HANDLER) {
      WriteLine("[BAHA_NATIVE_CRASH] diagnostic-failed\n");
    }
    InterlockedExchange(&logging_exception, 0);
  }
  if (previous_filter != nullptr && previous_filter != LogUnhandledException) {
    return previous_filter(exception);
  }
  // Preserve normal Windows error handling; do not suppress, recover, or exit.
  return EXCEPTION_CONTINUE_SEARCH;
}
}  // namespace

void InstallDebugCrashDiagnostics() {
  if (InterlockedCompareExchange(&installed, 1, 0) != 0) {
    return;
  }
  stderr_handle = GetStdHandle(STD_ERROR_HANDLE);
  previous_filter = SetUnhandledExceptionFilter(LogUnhandledException);
  wchar_t directory[kMaxPathCharacters] = {};
  if (LocalExecutableDirectory(
          directory, static_cast<DWORD>(kMaxPathCharacters)) &&
      DuplicateHandle(GetCurrentProcess(), GetCurrentProcess(),
                      GetCurrentProcess(), &symbol_process, 0, FALSE,
                      DUPLICATE_SAME_ACCESS)) {
    const auto old_options = SymGetOptions();
    SymSetOptions(kLocalSymbolOptions);
    symbols_ready = SymInitializeW(symbol_process, directory, TRUE) != FALSE;
    SymSetOptions(old_options);
  }
  WriteLine(
      "[BAHA_NATIVE_CRASH] installed maxFrames=32 localSymbols=%d "
      "previousFilter=%d\n",
      symbols_ready ? 1 : 0, previous_filter != nullptr ? 1 : 0);
}

#else

void InstallDebugCrashDiagnostics() {}

#endif  // defined(_DEBUG)
