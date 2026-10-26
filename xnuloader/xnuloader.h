/*
 * Copyright (c) 2026 HakiOS-x86 contributors. All rights reserved.
 *
 * HakiOS-x86 Boot Loader — UEFI x86_64 Application
 *
 * This is a UEFI application (PE64) that:
 *   1. Reads mach_kernel from the EFI System Partition
 *   2. Reads the kernel command line (from a file or UEFI variables)
 *   3. Allocates memory for the kernel
 *   4. Fills the BootArgs structure for x86_64
 *   5. Shuts down UEFI boot services
 *   6. Jumps to the XNU kernel entry point
 *
 * This is the x86_64 equivalent of the ARM64 xnuloader.
 * Like the original, it does not use EDK2 — it uses the raw
 * UEFI protocol interface from the firmware.
 *
 * APSL 2.0 — see NOTICE and COMPLIANCE.md.
 */

/* We use minimal UEFI type definitions (no EDK2 dependency) */

#ifndef _HAKIOS_XNULOADER_H_
#define _HAKIOS_XNULOADER_H_

/* Basic types */
typedef unsigned char       uint8_t;
typedef unsigned short      uint16_t;
typedef unsigned int        uint32_t;
typedef unsigned long long  uint64_t;
typedef unsigned long       uintptr_t;
typedef char                char8_t;
typedef unsigned short      char16_t;

/* UEFI function calling convention on x86_64: MS ABI */
#define EFIAPI __attribute__((ms_abi))

/* UEFI status codes */
#define EFI_SUCCESS         0
#define EFI_LOAD_ERROR      ((1ULL << 32) | 1)
#define EFI_INVALID_PARAMETER ((1ULL << 32) | 2)
#define EFI_UNSUPPORTED     ((1ULL << 32) | 3)
#define EFI_BAD_BUFFER_SIZE ((1ULL << 32) | 4)
#define EFI_BUFFER_TOO_SMALL ((1ULL << 32) | 5)
#define EFI_NOT_FOUND       ((1ULL << 32) | 14)
#define EFI_OUT_OF_RESOURCES ((1ULL << 32) | 15)

typedef uint64_t efi_status_t;
typedef void *efi_handle_t;

/* UEFI memory types */
#define EFI_LOADER_CODE    1
#define EFI_LOADER_DATA    2
#define EFI_BOOT_SERVICES_CODE  3
#define EFI_BOOT_SERVICES_DATA  4
#define EFI_RUNTIME_SERVICES_CODE 5
#define EFI_RUNTIME_SERVICES_DATA 6
#define EFI_CONVENTIONAL_MEMORY  7
#define EFI_UNUSABLE_MEMORY  8
#define EFI_ACPI_RECLAIM_MEMORY 9
#define EFI_ACPI_MEMORY_NVS  10
#define EFI_MMIO            11
#define EFI_MMIO_IOPORT     12
#define EFI_PAL_CODE        13
#define EFI_PERSISTENT_MEMORY 14

/* UEFI memory descriptor */
typedef struct {
    uint32_t type;
    uint32_t pad;
    uint64_t physical_start;
    uint64_t virtual_start;
    uint64_t number_of_pages;
    uint64_t attribute;
} efi_memory_descriptor_t;

/* UEFI table header */
typedef struct {
    uint64_t signature;
    uint32_t revision;
    uint32_t header_size;
    uint32_t crc32;
    uint32_t reserved;
} efi_table_header_t;

/* UEFI Runtime Services */
typedef struct {
    efi_table_header_t hdr;

    void *efi_get_time;
    void *efi_set_time;
    void *efi_get_wakeup_time;
    void *efi_set_wakeup_time;
    void *efi_set_virtual_address_map;
    void *efi_convert_pointer;
    void *efi_get_variable;
    void *efi_get_next_variable_name;
    void *efi_set_variable;
    void *efi_get_next_high_monotonic_count;
    void *efi_reset_system;
} efi_runtime_services_t;

/* UEFI Boot Services */
typedef struct efi_boot_services {
    efi_table_header_t hdr;

    void *efi_raise_tpl;
    void *efi_restore_tpl;

    efi_status_t (EFIAPI *efi_allocate_pages)(int alloc_type,
        int mem_type, uint64_t pages, efi_handle_t *memory);
    efi_status_t (EFIAPI *efi_free_pages)(efi_handle_t memory,
        uint64_t pages);
    efi_status_t (EFIAPI *efi_get_memory_map)(uint64_t *memory_map_size,
        void *memory_map, uint64_t *map_key, uint64_t *descriptor_size,
        uint32_t *descriptor_version);
    efi_status_t (EFIAPI *efi_allocate_pool)(int mem_type,
        uint64_t size, void **buffer);
    efi_status_t (EFIAPI *efi_free_pool)(void *buffer);

    void *efi_create_event;
    void *efi_set_timer;
    void *efi_wait_for_event;
    void *efi_signal_event;
    void *efi_close_event;
    void *efi_check_event;

    void *efi_install_protocol_interface;
    void *efi_reinstall_protocol_interface;
    void *efi_uninstall_protocol_interface;
    void *efi_handle_protocol;

    void *efi_register_protocol_notify;
    void *efi_locate_handle;
    void *efi_locate_protocol;

    void *efi_boot_services_data_1;
    void *efi_boot_services_data_2;
    void *efi_boot_services_data_3;

    efi_status_t (EFIAPI *efi_load_image)(int boot_policy,
        efi_handle_t parent_image, void *source, uint64_t source_size,
        void *source_buffer, uint64_t source_size2,
        efi_handle_t *image);
    efi_status_t (EFIAPI *efi_start_image)(efi_handle_t image,
        uint64_t *exit_data_size, char16_t **exit_data);
    efi_status_t (EFIAPI *efi_exit)(efi_handle_t image,
        efi_status_t exit_status, uint64_t exit_data_size,
        void *exit_data);
    void *efi_unload_image;

    efi_status_t (EFIAPI *efi_exit_boot_services)(efi_handle_t image_key,
        uint64_t map_key);

    void *remaining[16]; /* simplified */
} efi_boot_services_t;

/* UEFI System Table */
typedef struct {
    efi_table_header_t hdr;

    char16_t *firmware_vendor;
    uint32_t firmware_revision;
    efi_handle_t console_in_handle;
    void *con_in;
    efi_handle_t console_out_handle;
    void *con_out;
    efi_handle_t standard_error_handle;
    void *std_err;
    efi_runtime_services_t *runtime_services;
    efi_boot_services_t *boot_services;
    uint64_t number_of_table_entries;
    void *configuration_table;
} efi_system_table_t;

/* Simple file protocol (simplified) */
typedef struct efi_file_protocol efi_file_protocol_t;
typedef struct efi_simple_file_system_protocol efi_simple_file_system_protocol_t;

struct efi_file_protocol {
    uint64_t revision;
    efi_status_t (EFIAPI *open)(efi_file_protocol_t *this,
        efi_file_protocol_t **new_handle, char16_t *filename,
        uint64_t open_mode, uint64_t attributes);
    efi_status_t (EFIAPI *close)(efi_file_protocol_t *this);
    efi_status_t (EFIAPI *delete)(efi_file_protocol_t *this);
    efi_status_t (EFIAPI *read)(efi_file_protocol_t *this,
        uint64_t *buffer_size, void *buffer);
    efi_status_t (EFIAPI *write)(efi_file_protocol_t *this,
        uint64_t *buffer_size, void *buffer);
    efi_status_t (EFIAPI *get_position)(efi_file_protocol_t *this,
        uint64_t *position);
    efi_status_t (EFIAPI *set_position)(efi_file_protocol_t *this,
        uint64_t position);
    efi_status_t (EFIAPI *get_info)(efi_file_protocol_t *this,
        void *info_type, uint64_t *buffer_size, void *buffer);
    /* ... more fields ... */
};

struct efi_simple_file_system_protocol {
    uint64_t revision;
    efi_status_t (EFIAPI *open_volume)(
        efi_simple_file_system_protocol_t *this,
        efi_file_protocol_t **root);
};

/* UEFI loaded image protocol */
typedef struct {
    uint32_t revision;
    void *parent_handle;
    efi_system_table_t *system_table;
    void *device_handle;
    void *file_path;
    void *reserved;
    uint32_t load_options_size;
    void *load_options;
    void *image_base;
    uint64_t image_size;
    void *image_code_type;
    void *image_data_type;
    void *unload;
} efi_loaded_image_protocol_t;

/* XNU BootArgs for x86_64 */
typedef struct {
    uint16_t revision;
    uint16_t version;
    uint32_t efi_mode;
    uint32_t command_line_length;
    uint32_t command_line;
    uint32_t memory_map;
    uint32_t memory_map_size;
    uint32_t memory_map_descriptor_size;
    uint32_t memory_map_descriptor_version;
    uint32_t video_type;
    uint32_t video_base_addr;
    uint32_t video_row_bytes;
    uint32_t video_height;
    uint32_t video_width;
    uint32_t video_depth;
    uint64_t efi_runtime_services_page_start;
    uint64_t efi_runtime_services_page_count;
    uint64_t efi_runtime_services_virtual_page_table;
    uint32_t efi_system_table;
    uint32_t efi_runtime_services;
} boot_args_t;

#endif /* _HAKIOS_XNULOADER_H_ */
