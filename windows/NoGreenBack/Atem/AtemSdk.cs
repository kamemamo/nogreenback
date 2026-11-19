// ATEM Switchers SDK (Blackmagic の BMDSwitcherAPI。COM) を C# から使うための宣言 (SPEC.md 12 章)
// ATEM Software Control を入れると、BMDSwitcherAPI64.dll が COM として登録される。
// メソッドの並び (vtable の順) は SDK の Developer SDK/Windows/include/BMDSwitcherAPI.idl のとおり。
// 使わないメソッドは、並びを保つためだけに Slot_名前 として置いている (呼ばない)。

using System.Runtime.InteropServices;

namespace NoGreenBack.Atem;

static class AtemSdk
{
    public static readonly Guid CLSID_CBMDSwitcherDiscovery = new("8A13D4FA-4801-48E3-BF68-442D63E34500");
    public static readonly Guid IID_IBMDSwitcherMixEffectBlockIterator = typeof(IBMDSwitcherMixEffectBlockIterator).GUID;
    public static readonly Guid IID_IBMDSwitcherInputIterator = typeof(IBMDSwitcherInputIterator).GUID;

    public const uint PortTypeExternal = 0x6578746E;            // 'extn'
    public const uint EventTypeDisconnected = 0x73656469;       // 'sedi'
    public const uint ConnectToFailureIncompatibleFirmware = 0x63666966;   // 'cfif'


    /// ミックスの長さの 1 秒あたりのフレーム数 (ATEM は 50p / 60p でも 25 / 30 で数える)
    public static double FramesPerSecond(uint videoMode) => videoMode switch
    {
        0x70616C6C /* 625i50PAL */ or 0x70616C41 /* 625i50Anamorphic */ or 0x37327030 /* 720p50 */ or 0x31306930 /* 1080i50 */ or 0x31307035 /* 1080p25 */ or 0x31307030 /* 1080p50 */ or 0x34483235 /* 4KHDp25 */ or 0x34483530 /* 4KHDp50 */ or 0x38483235 /* 8KHDp25 */ or 0x38483530 /* 8KHDp50 */ => 25,
        0x31307033 /* 1080p2398 */ or 0x31307034 /* 1080p24 */ or 0x34483233 /* 4KHDp2398 */ or 0x34483234 /* 4KHDp24 */ or 0x38483233 /* 8KHDp2398 */ or 0x38483234 /* 8KHDp24 */ => 24,
        _ => 30,
    };
}

[ComImport, Guid("1EEE089A-5422-4A76-B068-F6EDCFBD3AC0"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IBMDSwitcherDiscovery
{
    [PreserveSig] int ConnectTo([MarshalAs(UnmanagedType.BStr)] string deviceAddress, out IBMDSwitcher switcherDevice, out uint failReason);
}

[ComImport, Guid("FD979282-9281-4FDC-8C1F-012F3FB12245"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IBMDSwitcher
{
    [PreserveSig] int GetProductName([MarshalAs(UnmanagedType.BStr)] out string productName);
    [PreserveSig] int GetVideoMode(out uint videoMode);
    void Slot_SetVideoMode();
    void Slot_DoesSupportVideoMode();
    void Slot_DoesVideoModeChangeRequireReconfiguration();
    void Slot_GetMethodForDownConvertedSD();
    void Slot_SetMethodForDownConvertedSD();
    void Slot_GetDownConvertedHDVideoMode();
    void Slot_SetDownConvertedHDVideoMode();
    void Slot_DoesSupportDownConvertedHDVideoMode();
    void Slot_GetMultiViewVideoMode();
    void Slot_SetMultiViewVideoMode();
    void Slot_DoesSupportMultiViewVideoMode();
    void Slot_Get3GSDIOutputLevel();
    void Slot_Set3GSDIOutputLevel();
    void Slot_DoesSupportColorimetrySetting();
    void Slot_GetColorimetryMode();
    void Slot_SetColorimetryMode();
    void Slot_GetPowerStatus();
    void Slot_GetTimeCode();
    void Slot_SetTimeCode();
    void Slot_RequestTimeCode();
    void Slot_GetTimeCodeLocked();
    void Slot_GetTimeCodeExternal();
    void Slot_GetTimeCodeMode();
    void Slot_SetTimeCodeMode();
    void Slot_GetAreOutputsConfigurable();
    void Slot_GetSuperSourceCascade();
    void Slot_SetSuperSourceCascade();
    void Slot_SuspendStreaming();
    void Slot_AllowStreamingToResume();
    void Slot_DoesSupportAutoVideoMode();
    void Slot_GetAutoVideoMode();
    void Slot_GetAutoVideoModeDetected();
    void Slot_SetAutoVideoMode();
    void Slot_DoesSupportFadeToBlackEnabledSetting();
    void Slot_GetFadeToBlackEnabled();
    void Slot_SetFadeToBlackEnabled();
    void Slot_DoesSupportDskTallyOverride();
    void Slot_GetDskTallyOverrideEnabled();
    void Slot_SetDskTallyOverrideEnabled();
    void Slot_DoesSupportTallyConfig();
    [PreserveSig] int CreateIterator(ref Guid iid, out IntPtr ppv);
    [PreserveSig] int AddCallback(IBMDSwitcherCallback callback);
    [PreserveSig] int RemoveCallback(IBMDSwitcherCallback callback);
}

[ComImport, Guid("EE50FC2C-D0D7-42D6-965A-57498CECC1F6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IBMDSwitcherCallback
{
    [PreserveSig] int Notify(uint eventType, uint coreVideoMode);
}

[ComImport, Guid("488EE33F-BEDB-46DA-9EF9-5BE2F570D759"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IBMDSwitcherMixEffectBlockIterator
{
    [PreserveSig] int Next(out IBMDSwitcherMixEffectBlock mixEffectBlock);
}

[ComImport, Guid("1F0A8C19-B39B-4B50-800B-63BC459FE6D5"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IBMDSwitcherMixEffectBlock
{
    [PreserveSig] int GetProgramInput(out long value);
    [PreserveSig] int SetProgramInput(long value);
    void Slot_GetPreviewInput();
    [PreserveSig] int SetPreviewInput(long value);
    void Slot_GetPreviewLive();
    void Slot_GetPreviewTransition();
    void Slot_SetPreviewTransition();
    [PreserveSig] int PerformAutoTransition();
    void Slot_PerformCut();
    void Slot_GetInTransition();
    void Slot_GetTransitionPosition();
    void Slot_SetTransitionPosition();
    void Slot_GetTransitionFramesRemaining();
    void Slot_PerformFadeToBlack();
    void Slot_GetFadeToBlackRate();
    void Slot_SetFadeToBlackRate();
    void Slot_GetFadeToBlackFramesRemaining();
    void Slot_GetFadeToBlackFullyBlack();
    void Slot_SetFadeToBlackFullyBlack();
    void Slot_GetInFadeToBlack();
    void Slot_GetFadeToBlackInTransition();
    void Slot_GetInputAvailabilityMask();
    void Slot_SetTallyConfig();
    void Slot_GetTallyConfig();
    void Slot_CreateIterator();
    void Slot_AddCallback();
    void Slot_RemoveCallback();
}

[ComImport, Guid("759CFA56-DE34-43C6-8E85-A8B4108A7E80"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IBMDSwitcherInputIterator
{
    [PreserveSig] int Next(out IBMDSwitcherInput input);
    void Slot_GetById();
}

[ComImport, Guid("78B814D6-E98D-47B0-8B9A-0429DF56E462"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IBMDSwitcherInput
{
    [PreserveSig] int GetPortType(out uint type);
    void Slot_GetInputAvailability();
    void Slot_SetShortName();
    void Slot_GetShortName();
    void Slot_SetLongName();
    [PreserveSig] int GetLongName([MarshalAs(UnmanagedType.BStr)] out string name);
    void Slot_AreNamesDefault();
    void Slot_ResetNames();
    void Slot_IsProgramTallied();
    void Slot_IsPreviewTallied();
    void Slot_GetAvailableExternalPortTypes();
    void Slot_SetCurrentExternalPortType();
    void Slot_GetCurrentExternalPortType();
    void Slot_SetCameraModel();
    void Slot_GetCameraModel();
    void Slot_DoesSupportCameraModel();
    void Slot_SetViscaDeviceId();
    void Slot_GetViscaDeviceId();
    [PreserveSig] int GetInputId(out long inputId);
    void Slot_AddCallback();
    void Slot_RemoveCallback();
}

[ComImport, Guid("4C5D18C9-0955-4525-9947-527EA0679140"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IBMDSwitcherTransitionMixParameters
{
    [PreserveSig] int GetRate(out uint frames);
    [PreserveSig] int SetRate(uint frames);
    void Slot_AddCallback();
    void Slot_RemoveCallback();
}
