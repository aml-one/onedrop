#ifndef RUNNER_DROP_P2P_PLUGIN_H_
#define RUNNER_DROP_P2P_PLUGIN_H_

#include <flutter/binary_messenger.h>
#include <windows.h>

void RegisterDropP2pPlugin(flutter::BinaryMessenger* messenger, HWND host_window);
bool DropP2pHandleMessage(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam);

#endif
