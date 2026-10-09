// d3dprobe: creates a D3D11 (or D3D12) device and prints what it got, so a backend can be
// checked without a game. Build with tools/d3dprobe/build.sh; run through `neutron run`.
//
//   d3dprobe.exe        D3D11 device + adapter info
//   d3dprobe.exe 12     D3D12 device
//   d3dprobe.exe 9      D3D9 device (HAL, hidden window) + adapter info
//   d3dprobe.exe shared D3D11 shared texture: GetSharedHandle on one device, open on another
//                       (what Media Foundation video playback in Unity relies on)
//   d3dprobe.exe timestamp  D3D11 timestamp + disjoint queries around a clear (what Unreal's GPU
//                       timing and its timestamp calibration rely on)
//
// Exit code 0 means the device was created.
#define COBJMACROS
#define INITGUID
#include <windows.h>
#include <stdio.h>
#include <d3d11.h>
#include <d3d12.h>
#include <d3d9.h>
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

static int probe_d3d9(void) {
    IDirect3D9 *d3d = Direct3DCreate9(D3D_SDK_VERSION);
    if (!d3d) {
        printf("Direct3DCreate9 failed\n");
        return 1;
    }
    D3DADAPTER_IDENTIFIER9 id;
    if (SUCCEEDED(IDirect3D9_GetAdapterIdentifier(d3d, D3DADAPTER_DEFAULT, 0, &id))) {
        printf("adapter: %s (vendor 0x%04lx, device 0x%04lx)\n", id.Description, id.VendorId, id.DeviceId);
    }
    HWND window = CreateWindowA("STATIC", "d3dprobe", WS_OVERLAPPEDWINDOW, 0, 0, 320, 240, NULL, NULL, NULL, NULL);
    D3DPRESENT_PARAMETERS pp = {0};
    pp.Windowed = TRUE;
    pp.SwapEffect = D3DSWAPEFFECT_DISCARD;
    pp.BackBufferFormat = D3DFMT_UNKNOWN;
    pp.hDeviceWindow = window;
    IDirect3DDevice9 *device = NULL;
    HRESULT hr = IDirect3D9_CreateDevice(d3d, D3DADAPTER_DEFAULT, D3DDEVTYPE_HAL, window,
                                         D3DCREATE_HARDWARE_VERTEXPROCESSING, &pp, &device);
    if (FAILED(hr)) {
        printf("IDirect3D9::CreateDevice failed: 0x%08lx\n", (unsigned long)hr);
        IDirect3D9_Release(d3d);
        return 1;
    }
    hr = IDirect3DDevice9_Clear(device, 0, NULL, D3DCLEAR_TARGET, D3DCOLOR_XRGB(0, 0, 255), 1.0f, 0);
    if (SUCCEEDED(hr)) hr = IDirect3DDevice9_Present(device, NULL, NULL, NULL, NULL);
    printf("D3D9 device created; clear+present %s\n", SUCCEEDED(hr) ? "ok" : "failed");
    IDirect3DDevice9_Release(device);
    IDirect3D9_Release(d3d);
    DestroyWindow(window);
    return SUCCEEDED(hr) ? 0 : 1;
}

static ID3D11Device *create_device(void) {
    ID3D11Device *device = NULL;
    D3D11CreateDevice(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, D3D11_CREATE_DEVICE_BGRA_SUPPORT, NULL, 0,
                      D3D11_SDK_VERSION, &device, NULL, NULL);
    return device;
}

static int probe_shared(void) {
    ID3D11Device *a = create_device(), *b = create_device();
    if (!a || !b) { printf("D3D11CreateDevice failed\n"); return 1; }
    int failures = 0;
    UINT flags[] = {D3D11_RESOURCE_MISC_SHARED, D3D11_RESOURCE_MISC_SHARED_KEYEDMUTEX, 0};
    const char *names[] = {"MISC_SHARED", "MISC_SHARED_KEYEDMUTEX", "no shared flag"};
    for (int i = 0; i < 3; i++) {
        D3D11_TEXTURE2D_DESC desc = {256, 256, 1, 1, DXGI_FORMAT_B8G8R8A8_UNORM, {1, 0}, D3D11_USAGE_DEFAULT,
                                     D3D11_BIND_SHADER_RESOURCE | D3D11_BIND_RENDER_TARGET, 0, flags[i]};
        ID3D11Texture2D *texture = NULL;
        HRESULT hr = ID3D11Device_CreateTexture2D(a, &desc, NULL, &texture);
        if (FAILED(hr)) { printf("%-24s CreateTexture2D failed: 0x%08lx\n", names[i], (unsigned long)hr); failures++; continue; }
        IDXGIResource *resource = NULL;
        HANDLE handle = NULL;
        ID3D11Texture2D_QueryInterface(texture, &IID_IDXGIResource, (void **)&resource);
        hr = resource ? IDXGIResource_GetSharedHandle(resource, &handle) : E_NOINTERFACE;
        ID3D11Texture2D *opened = NULL;
        HRESULT open = handle ? ID3D11Device_OpenSharedResource(b, handle, &IID_ID3D11Texture2D, (void **)&opened) : E_HANDLE;
        printf("%-24s GetSharedHandle 0x%08lx handle %p, OpenSharedResource 0x%08lx\n", names[i],
               (unsigned long)hr, handle, (unsigned long)open);
        if (flags[i] && (FAILED(hr) || !handle || FAILED(open))) failures++;
        if (opened) ID3D11Texture2D_Release(opened);
        if (resource) IDXGIResource_Release(resource);
        ID3D11Texture2D_Release(texture);
    }
    ID3D11Device_Release(a);
    ID3D11Device_Release(b);
    return failures ? 1 : 0;
}

static HRESULT wait_data(ID3D11DeviceContext *context, ID3D11Query *query, void *data, UINT size) {
    HRESULT hr = S_FALSE;
    for (int i = 0; i < 2000 && hr == S_FALSE; i++) {
        hr = ID3D11DeviceContext_GetData(context, (ID3D11Asynchronous *)query, data, size, 0);
        if (hr == S_FALSE) Sleep(1);
    }
    return hr;
}

static int probe_timestamp(void) {
    ID3D11Device *device = NULL;
    ID3D11DeviceContext *context = NULL;
    if (FAILED(D3D11CreateDevice(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, NULL, 0, D3D11_SDK_VERSION,
                                 &device, NULL, &context))) { printf("D3D11CreateDevice failed\n"); return 1; }
    D3D11_QUERY_DESC disjoint_desc = {D3D11_QUERY_TIMESTAMP_DISJOINT, 0}, ts_desc = {D3D11_QUERY_TIMESTAMP, 0};
    ID3D11Query *disjoint = NULL, *begin = NULL, *end = NULL;
    HRESULT hr = ID3D11Device_CreateQuery(device, &disjoint_desc, &disjoint);
    printf("CreateQuery(TIMESTAMP_DISJOINT) 0x%08lx\n", (unsigned long)hr);
    hr = ID3D11Device_CreateQuery(device, &ts_desc, &begin);
    printf("CreateQuery(TIMESTAMP)          0x%08lx\n", (unsigned long)hr);
    ID3D11Device_CreateQuery(device, &ts_desc, &end);
    if (!disjoint || !begin || !end) return 1;

    D3D11_TEXTURE2D_DESC desc = {256, 256, 1, 1, DXGI_FORMAT_R8G8B8A8_UNORM, {1, 0}, D3D11_USAGE_DEFAULT,
                                 D3D11_BIND_RENDER_TARGET, 0, 0};
    ID3D11Texture2D *texture = NULL;
    ID3D11RenderTargetView *rtv = NULL;
    ID3D11Device_CreateTexture2D(device, &desc, NULL, &texture);
    ID3D11Device_CreateRenderTargetView(device, (ID3D11Resource *)texture, NULL, &rtv);
    float color[4] = {1, 0, 0, 1};

    int failures = 0;
    for (int frame = 0; frame < 3; frame++) {
        ID3D11DeviceContext_Begin(context, (ID3D11Asynchronous *)disjoint);
        ID3D11DeviceContext_End(context, (ID3D11Asynchronous *)begin);
        for (int i = 0; i < 100; i++) ID3D11DeviceContext_ClearRenderTargetView(context, rtv, color);
        ID3D11DeviceContext_End(context, (ID3D11Asynchronous *)end);
        ID3D11DeviceContext_End(context, (ID3D11Asynchronous *)disjoint);
        ID3D11DeviceContext_Flush(context);

        D3D11_QUERY_DATA_TIMESTAMP_DISJOINT dj = {0};
        UINT64 t0 = 0, t1 = 0;
        HRESULT h0 = wait_data(context, disjoint, &dj, sizeof(dj));
        HRESULT h1 = wait_data(context, begin, &t0, sizeof(t0));
        HRESULT h2 = wait_data(context, end, &t1, sizeof(t1));
        printf("frame %d: disjoint 0x%08lx freq %llu disjoint=%d; begin 0x%08lx %llu; end 0x%08lx %llu; delta %lld\n",
               frame, (unsigned long)h0, (unsigned long long)dj.Frequency, dj.Disjoint, (unsigned long)h1,
               (unsigned long long)t0, (unsigned long)h2, (unsigned long long)t1, (long long)(t1 - t0));
        if (h0 != S_OK || h1 != S_OK || h2 != S_OK || !dj.Frequency || dj.Disjoint || t1 < t0) failures++;
    }
    return failures ? 1 : 0;
}

int main(int argc, char **argv) {
    const char *mode = argc > 1 ? argv[1] : "11";
    int result = strcmp(mode, "12") == 0 ? probe_d3d12() : strcmp(mode, "9") == 0 ? probe_d3d9()
               : strcmp(mode, "shared") == 0 ? probe_shared()
               : strcmp(mode, "timestamp") == 0 ? probe_timestamp() : probe_d3d11();
    printf("modules:\n");
    print_module("d3d11.dll");
    print_module("d3d12.dll");
    print_module("d3d9.dll");
    print_module("dxgi.dll");
    print_module("winemetal.dll");
    print_module("wined3d.dll");
    return result;
}
