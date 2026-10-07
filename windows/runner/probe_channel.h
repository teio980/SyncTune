#ifndef RUNNER_PROBE_CHANNEL_H_
#define RUNNER_PROBE_CHANNEL_H_

#include <windows.h>

#include <flutter/flutter_engine.h>
#include <flutter/method_channel.h>

#include <atomic>
#include <memory>

std::unique_ptr<flutter::MethodChannel<>> RegisterProbeChannel(
    flutter::FlutterEngine* engine,
    HWND window,
    std::shared_ptr<std::atomic_bool> alive);

#endif  // RUNNER_PROBE_CHANNEL_H_
