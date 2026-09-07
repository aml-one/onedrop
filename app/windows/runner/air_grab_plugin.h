#ifndef RUNNER_AIR_GRAB_PLUGIN_H_
#define RUNNER_AIR_GRAB_PLUGIN_H_

#include <flutter/binary_messenger.h>
#include <windows.h>

void RegisterAirGrabPlugin(flutter::BinaryMessenger* messenger, HWND host_window);
bool AirGrabHandleMessage(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam);

#endif  // RUNNER_AIR_GRAB_PLUGIN_H_
