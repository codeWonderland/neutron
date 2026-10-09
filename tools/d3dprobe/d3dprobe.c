// d3dprobe: creates a D3D11 (or D3D12) device and prints what it got, so a backend can be
// checked without a game. Build with tools/d3dprobe/build.sh; run through `neutron run`.
//
//   d3dprobe.exe        D3D11 device + adapter info
//   d3dprobe.exe 12     D3D12 device
//
// Exit code 0 means the device was created.
#define COBJMACROS
#define INITGUID
#include <windows.h>
#include <stdio.h>
#include <d3d11.h>
#include <d3d12.h>
#include <dxgi.h>

static void print_module(const char *name) {
    HMODULE module = GetModuleHandleA(name);
    char path[MAX_PATH] = "(not loaded)";
    if (module) GetModuleFileNameA(module, path, sizeof(path));
    printf("  %-14s %s\n", name, path);
}

static void print_adapter(IDXGIAdapter *adapter) {
    DXGI_ADAPTER_DESC desc;
    if (SUCCEEDED(IDXGIAdapter_GetDesc(adapter, &desc))) {
        printf("adapter: %ls (vendor 0x%04x, device 0x%04x, %llu MB VRAM)\n", desc.Description,
               desc.VendorId, desc.DeviceId, (unsigned long long)(desc.DedicatedVideoMemory >> 20));
    }
}

static int probe_d3d11(void) {
    ID3D11Device *device = NULL;
    ID3D11DeviceContext *context = NULL;
    D3D_FEATURE_LEVEL level = 0;
    HRESULT hr = D3D11CreateDevice(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, NULL, 0,
                                   D3D11_SDK_VERSION, &device, &level, &context);
    if (FAILED(hr)) {
        printf("D3D11CreateDevice failed: 0x%08lx\n", (unsigned long)hr);
        return 1;
    }
    printf("D3D11 device created, feature level %u.%u\n", (level >> 12) & 0xf, (level >> 8) & 0xf);

    IDXGIDevice *dxgi = NULL;
    IDXGIAdapter *adapter = NULL;
    if (SUCCEEDED(ID3D11Device_QueryInterface(device, &IID_IDXGIDevice, (void **)&dxgi)) &&
        SUCCEEDED(IDXGIDevice_GetAdapter(dxgi, &adapter))) {
        print_adapter(adapter);
        IDXGIAdapter_Release(adapter);
    }
    if (dxgi) IDXGIDevice_Release(dxgi);
    ID3D11DeviceContext_Release(context);
    ID3D11Device_Release(device);
    return 0;
}

static int probe_d3d12(void) {
    HMODULE d3d12 = LoadLibraryA("d3d12.dll");
    if (!d3d12) {
        printf("d3d12.dll could not be loaded (error %lu)\n", GetLastError());
        return 1;
    }
    PFN_D3D12_CREATE_DEVICE create = (PFN_D3D12_CREATE_DEVICE)(void *)GetProcAddress(d3d12, "D3D12CreateDevice");
    ID3D12Device *device = NULL;
    HRESULT hr = create ? create(NULL, D3D_FEATURE_LEVEL_11_0, &IID_ID3D12Device, (void **)&device) : E_NOINTERFACE;
    if (FAILED(hr)) {
        printf("D3D12CreateDevice failed: 0x%08lx\n", (unsigned long)hr);
        return 1;
    }
    printf("D3D12 device created\n");
    ID3D12Device_Release(device);
    return 0;
}

int main(int argc, char **argv) {
    int result = (argc > 1 && strcmp(argv[1], "12") == 0) ? probe_d3d12() : probe_d3d11();
    printf("modules:\n");
    print_module("d3d11.dll");
    print_module("d3d12.dll");
    print_module("dxgi.dll");
    print_module("winemetal.dll");
    print_module("wined3d.dll");
    return result;
}
