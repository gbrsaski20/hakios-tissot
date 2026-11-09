## @file
#
#  Copyright (c) 2011-2015, ARM Limited. All rights reserved.
#  Copyright (c) 2014, Linaro Limited. All rights reserved.
#  Copyright (c) 2015 - 2016, Intel Corporation. All rights reserved.
#  Copyright (c) 2018 - 2019, Bingxing Wang. All rights reserved.
#  Copyright (c) 2022, Xilin Wu. All rights reserved.
#
#  SPDX-License-Identifier: BSD-2-Clause-Patent
#
##

################################################################################
#
# Defines Section - statements that will be processed to create a Makefile.
#
################################################################################

[Defines]
  SOC_PLATFORM            = MSM8953
  USE_PHYSICAL_TIMER      = TRUE

!include Silicon/Qualcomm/QcomPkg/QcomCommonDsc.inc

[PcdsFixedAtBuild.common]
  # Memory layout: see devices/tissot/reference/memory-map.md (from a phone's /proc/iomem and FDT). Only RAM at or above
  # 0x8ef00000 is used: the 0x10000000-0x849fffff range reported by that phone is not trusted (see the note there).
  gArmTokenSpaceGuid.PcdSystemMemoryBase|0x8EF00000         # first usable RAM above the modem/adsp/wcnss carve-outs
  gArmTokenSpaceGuid.PcdSystemMemorySize|0x71100000         # up to 0xFFFFFFFF; the pstore hole is mapped no-map by the memory map

  gArmTokenSpaceGuid.PcdCpuVectorBaseAddress|0xA2000000     # CPU Vectors
  gArmTokenSpaceGuid.PcdArmArchTimerFreqInHz|19200000
  # arch timer PPIs of the phone's own tree: <1 2> secure phys, <1 3> non-secure phys, <1 4> virt, <1 1> hyp (PPI n = INTID 16+n)
  gArmTokenSpaceGuid.PcdArmArchTimerSecIntrNum|18
  gArmTokenSpaceGuid.PcdArmArchTimerIntrNum|19
  gArmTokenSpaceGuid.PcdArmArchTimerVirtIntrNum|20
  gArmTokenSpaceGuid.PcdArmArchTimerHypIntrNum|17
  # GICv2 (qcom,msm-qgic2): distributor 0x0b000000, CPU interface 0x0b002000. No redistributors.
  gArmTokenSpaceGuid.PcdGicDistributorBase|0x0b000000
  gArmTokenSpaceGuid.PcdGicInterruptInterfaceBase|0x0b002000

  gEmbeddedTokenSpaceGuid.PcdPrePiStackBase|0xA2050000      # UEFI Stack
  gEmbeddedTokenSpaceGuid.PcdPrePiStackSize|0x00040000      # 256K stack
  gEmbeddedTokenSpaceGuid.PcdPrePiCpuIoSize|44

  gQcomTokenSpaceGuid.PcdUefiMemPoolBase|0xA2100000         # DXE Heap base address
  gQcomTokenSpaceGuid.PcdUefiMemPoolSize|0x1E000000         # DXE heap size
  # The bootloader's splash framebuffer (FDT splash_region@0x90001000); assumed to be what LK is scanning out, not verified.
  gQcomTokenSpaceGuid.PcdMipiFrameBufferAddress|0x90001000

  gArmPlatformTokenSpaceGuid.PcdCoreCount|8
  gArmPlatformTokenSpaceGuid.PcdClusterCount|2

  #
  # SimpleInit
  #
  gSimpleInitTokenSpaceGuid.PcdDeviceTreeStore|0xA1F00000
  gSimpleInitTokenSpaceGuid.PcdLoggerdUseConsole|FALSE

[LibraryClasses.common]
  # Ported from SurfaceDuoPkg
  AslUpdateLib|Silicon/Qualcomm/QcomPkg/Library/DxeAslUpdateLib/DxeAslUpdateLib.inf

  PlatformMemoryMapLib|Silicon/Qualcomm/msm8953/Library/PlatformMemoryMapLib/PlatformMemoryMapLib.inf
  PlatformPeiLib|Silicon/Qualcomm/msm8953/Library/PlatformPeiLib/PlatformPeiLib.inf
  PlatformPrePiLib|Silicon/Qualcomm/msm8953/Library/PlatformPrePiLib/PlatformPrePiLib.inf
  MsPlatformDevicesLib|Silicon/Qualcomm/msm8953/Library/MsPlatformDevicesLib/MsPlatformDevicesLib.inf
  SOCSmbiosInfoLib|Silicon/Qualcomm/msm8953/Library/SOCSmbiosInfoLib/SOCSmbiosInfoLib.inf

[Components.common]
  