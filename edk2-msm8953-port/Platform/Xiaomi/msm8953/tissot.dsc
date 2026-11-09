[Defines]
  VENDOR_NAME                    = Xiaomi
  PLATFORM_NAME                  = tissot
  PLATFORM_GUID                  = 7c0e8953-5a11-4d6e-9b3a-2f1c8d4e6a07
  PLATFORM_VERSION               = 0.1
  DSC_SPECIFICATION              = 0x00010019
  OUTPUT_DIRECTORY               = Build/$(PLATFORM_NAME)
  SUPPORTED_ARCHITECTURES        = AARCH64
  BUILD_TARGETS                  = DEBUG|RELEASE
  SKUID_IDENTIFIER               = DEFAULT
  FLASH_DEFINITION               = Platform/Qualcomm/msm8953/msm8953.fdf
  DEVICE_DXE_FV_COMPONENTS       = Platform/Xiaomi/msm8953/tissot.fdf.inc

!include Platform/Qualcomm/msm8953/msm8953.dsc

[BuildOptions.common]
  GCC:*_*_AARCH64_CC_FLAGS = -DENABLE_SIMPLE_INIT

[PcdsFixedAtBuild.common]
  gQcomTokenSpaceGuid.PcdMipiFrameBufferWidth|1080
  gQcomTokenSpaceGuid.PcdMipiFrameBufferHeight|1920
  # The scanout is 24 bit packed (3 bytes per pixel): the stripe geometry in photos of test patterns matches 24, not 32
  gQcomTokenSpaceGuid.PcdMipiFrameBufferPixelBpp|24

  # Simple Init
  gSimpleInitTokenSpaceGuid.PcdGuiDefaultDPI|350

  gRenegadePkgTokenSpaceGuid.PcdDeviceVendor|"Xiaomi"
  gRenegadePkgTokenSpaceGuid.PcdDeviceProduct|"Mi A1"
  gRenegadePkgTokenSpaceGuid.PcdDeviceCodeName|"tissot"
