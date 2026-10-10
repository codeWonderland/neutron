// D3D8 mode of d3dprobe, in its own file because d3d8.h and d3d9.h define clashing types.
#define COBJMACROS
#include <windows.h>
#include <stdio.h>
#include <d3d8.h>

int probe_d3d8(void) {
    /* Loaded at runtime: 64-bit mingw ships no d3d8 import library. */
    HMODULE module = LoadLibraryA("d3d8.dll");
    IDirect3D8 *(WINAPI *create)(UINT) = module ? (void *)GetProcAddress(module, "Direct3DCreate8") : NULL;
    IDirect3D8 *d3d = create ? create(D3D_SDK_VERSION) : NULL;
    if (!d3d) {
        printf("Direct3DCreate8 failed\n");
        return 1;
    }
    D3DADAPTER_IDENTIFIER8 id;
    if (SUCCEEDED(IDirect3D8_GetAdapterIdentifier(d3d, D3DADAPTER_DEFAULT, 0, &id))) {
        printf("adapter: %s (vendor 0x%04lx, device 0x%04lx)\n", id.Description, id.VendorId, id.DeviceId);
    }
    D3DDISPLAYMODE mode;
    IDirect3D8_GetAdapterDisplayMode(d3d, D3DADAPTER_DEFAULT, &mode);
    HWND window = CreateWindowA("STATIC", "d3dprobe", WS_OVERLAPPEDWINDOW, 0, 0, 320, 240, NULL, NULL, NULL, NULL);
    D3DPRESENT_PARAMETERS pp = {0};
    pp.Windowed = TRUE;
    pp.SwapEffect = D3DSWAPEFFECT_DISCARD;
    pp.BackBufferFormat = mode.Format;
    pp.hDeviceWindow = window;
    IDirect3DDevice8 *device = NULL;
    HRESULT hr = IDirect3D8_CreateDevice(d3d, D3DADAPTER_DEFAULT, D3DDEVTYPE_HAL, window,
                                         D3DCREATE_HARDWARE_VERTEXPROCESSING, &pp, &device);
    if (FAILED(hr)) {
        printf("IDirect3D8::CreateDevice failed: 0x%08lx\n", (unsigned long)hr);
        IDirect3D8_Release(d3d);
        return 1;
    }
    hr = IDirect3DDevice8_Clear(device, 0, NULL, D3DCLEAR_TARGET, D3DCOLOR_XRGB(0, 255, 0), 1.0f, 0);
    if (SUCCEEDED(hr)) hr = IDirect3DDevice8_Present(device, NULL, NULL, NULL, NULL);
    printf("D3D8 device created; clear+present %s\n", SUCCEEDED(hr) ? "ok" : "failed");
    IDirect3DDevice8_Release(device);
    IDirect3D8_Release(d3d);
    DestroyWindow(window);
    return SUCCEEDED(hr) ? 0 : 1;
}
