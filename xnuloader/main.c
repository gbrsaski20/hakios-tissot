/*
 * Copyright (c) 2026 HakiOS-x86 contributors. All rights reserved.
 *
 * HakiOS-x86 Boot Loader — Main Entry Point
 *
 * This is the UEFI entry point (efi_main). It is called by the
 * UEFI firmware when our application is loaded.
 *
 * Flow:
 *   1. Get the EFI System Table and Loaded Image Protocol
 *   2. Open the EFI System Partition (ESP) filesystem
 *   3. Read mach_kernel from \EFI\HAKIOS\mach_kernel
 *   4. Read kernel command line from \EFI\HAKIOS\cmdline.txt
 *   5. Allocate memory for the kernel
 *   6. Load the kernel into allocated memory
 *   7. Get the EFI memory map
 *   8. Fill BootArgs structure
 *   9. Exit UEFI Boot Services
 *  10. Jump to the kernel entry point
 *
 * APSL 2.0 — see NOTICE and COMPLIANCE.md.
 */

#include "xnuloader.h"

/* UEFI GUID for protocols we need */

/* EFI_LOADED_IMAGE_PROTOCOL GUID */
static const uint8_t guid_loaded_image[16] = {
    0x5b, 0x1b, 0x31, 0xa1, 0x04, 0x11, 0xd4, 0x4a,
    0x90, 0x77, 0x00, 0x40, 0x06, 0x14, 0x23, 0x3c
};

/* EFI_SIMPLE_FILE_SYSTEM_PROTOCOL GUID */
static const uint8_t guid_simple_fs[16] = {
    0x46, 0xfc, 0x12, 0x09, 0x67, 0x47, 0xd4, 0x44,
    0x8e, 0x0f, 0x33, 0x43, 0x3f, 0x4e, 0x39, 0x4c
};

/* Locally known GUIDs */
#define LOADED_IMAGE_GUID  (efi_guid_t){0xa1c2b05b, 0x0411, 0x4ad4, {0x90, 0x77, 0x00, 0x40, 0x06, 0x14, 0x23, 0x3c}}
#define SIMPLE_FS_GUID     (efi_guid_t){0x09fc46, 0x4767, 0x44d4, {0x8e, 0x0f, 0x33, 0x43, 0x3f, 0x4e, 0x39, 0x4c}}

typedef struct {
    uint32_t data1;
    uint16_t data2;
    uint16_t data3;
    uint8_t  data4[8];
} efi_guid_t;

/* Console output helper */
static efi_system_table_t *g_st = NULL;

static void
console_print(const char16_t *str)
{
    if (!g_st || !g_st->con_out)
        return;

    /* UEFI ConOut->OutputString */
    typedef efi_status_t (EFIAPI *output_string_t)(void *this, char16_t *str);
    output_string_t output_string =
        *(output_string_t *)((char *)g_st->con_out + 0x08);
    output_string(g_st->con_out, (char16_t *)str);
}

static void
console_print_ascii(const char *str)
{
    /* Convert ASCII to UTF-16 and print */
    char16_t buf[256];
    int i = 0;
    while (str[i] && i < 255) {
        buf[i] = (char16_t)(uint8_t)str[i];
        i++;
    }
    buf[i] = 0;
    console_print(buf);
}

/* ============================================================================
 * Memory functions
 * ============================================================================
 */

static void *
hakios_memcpy(void *dst, const void *src, uint64_t n)
{
    uint8_t *d = (uint8_t *)dst;
    const uint8_t *s = (const uint8_t *)src;
    while (n--)
        *d++ = *s++;
    return dst;
}

static int
hakios_memcmp(const void *a, const void *b, uint64_t n)
{
    const uint8_t *pa = (const uint8_t *)a;
    const uint8_t *pb = (const uint8_t *)b;
    while (n--) {
        if (*pa != *pb)
            return *pa - *pb;
        pa++;
        pb++;
    }
    return 0;
}

static void *
hakios_memset(void *dst, int c, uint64_t n)
{
    uint8_t *d = (uint8_t *)dst;
    while (n--)
        *d++ = (uint8_t)c;
    return dst;
}

/* ============================================================================
 * File reading
 * ============================================================================
 */

static efi_status_t
hakios_read_file(efi_file_protocol_t *root, const char16_t *filename,
                 void **buffer, uint64_t *size)
{
    efi_file_protocol_t *file = NULL;
    efi_status_t status;

    /* Open the file */
    status = root->open(root, &file, (char16_t *)filename, 1, 0);
    if (status != EFI_SUCCESS) {
        console_print_ascii("HakiOS: file not found: ");
        /* Convert filename to ASCII for printing */
        char name[128];
        int i;
        for (i = 0; i < 127 && filename[i]; i++)
            name[i] = (char)(filename[i] & 0xFF);
        name[i] = 0;
        console_print_ascii(name);
        console_print_ascii("\r\n");
        return status;
    }

    /* Get file size: seek to end, get position, seek back */
    status = file->set_position(file, 0xFFFFFFFFFFFFFFFFULL);
    if (status != EFI_SUCCESS) {
        file->close(file);
        return status;
    }

    uint64_t file_size = 0;
    status = file->get_position(file, &file_size);
    if (status != EFI_SUCCESS) {
        file->close(file);
        return status;
    }

    file->set_position(file, 0);

    /* Allocate memory for the file */
    uint64_t pages = (file_size + 4095) / 4096;
    efi_handle_t mem_handle = NULL;
    status = g_st->boot_services->efi_allocate_pages(
        0, EFI_LOADER_CODE, pages, &mem_handle);
    if (status != EFI_SUCCESS) {
        file->close(file);
        return status;
    }

    /* Read the file */
    *buffer = (void *)mem_handle;
    *size = file_size;
    status = file->read(file, &file_size, *buffer);
    file->close(file);

    if (status != EFI_SUCCESS) {
        g_st->boot_services->efi_free_pages(mem_handle, pages);
        return status;
    }

    return EFI_SUCCESS;
}

/* ============================================================================
 * Get the EFI memory map
 * ============================================================================
 */

static efi_status_t
hakios_get_memory_map(void **map, uint64_t *map_size,
                     uint64_t *map_key, uint64_t *desc_size)
{
    efi_status_t status;

    /* First call to get size */
    *map_size = 0;
    *map = NULL;
    status = g_st->boot_services->efi_get_memory_map(
        map_size, NULL, map_key, desc_size, NULL);

    if (status != EFI_BUFFER_TOO_SMALL)
        return EFI_LOAD_ERROR;

    /* Allocate buffer with extra space (allocating changes the map) */
    *map_size += *desc_size * 2;
    status = g_st->boot_services->efi_allocate_pool(
        EFI_LOADER_DATA, *map_size, map);
    if (status != EFI_SUCCESS)
        return status;

    /* Second call to get the actual map */
    status = g_st->boot_services->efi_get_memory_map(
        map_size, *map, map_key, desc_size, NULL);

    return status;
}

/* ============================================================================
 * UEFI entry point
 * ============================================================================
 */

efi_status_t EFIAPI
efi_main(efi_handle_t image_handle, efi_system_table_t *system_table)
{
    g_st = system_table;

    console_print_ascii("\r\n");
    console_print_ascii("=== HakiOS-x86 Boot Loader ===\r\n");
    console_print_ascii("Copyright (c) 2026 HakiOS-x86 contributors\r\n\r\n");

    /* ---- 1. Get Loaded Image Protocol ---- */
    /* This gives us the device handle for the ESP */
    efi_loaded_image_protocol_t *loaded_image = NULL;

    /* We need HandleProtocol to get the loaded image */
    efi_status_t status;

    /* Allocate pool for loaded image */
    status = g_st->boot_services->efi_allocate_pool(
        EFI_LOADER_DATA, sizeof(efi_loaded_image_protocol_t),
        (void **)&loaded_image);
    if (status != EFI_SUCCESS) {
        console_print_ascii("Error: cannot allocate for loaded image\r\n");
        return EFI_LOAD_ERROR;
    }

    /* Get the loaded image protocol using HandleProtocol */
    typedef efi_status_t (EFIAPI *handle_protocol_t)(
        efi_handle_t, efi_guid_t *, void **);
    handle_protocol_t handle_protocol =
        *(handle_protocol_t *)((char *)g_st->boot_services + 0x98);

    efi_guid_t loaded_image_guid = LOADED_IMAGE_GUID;
    status = handle_protocol(image_handle, &loaded_image_guid,
                             (void **)&loaded_image);
    if (status != EFI_SUCCESS) {
        console_print_ascii("Error: cannot get loaded image\r\n");
        return status;
    }

    console_print_ascii("Loaded image base: ");
    char hexbuf[32];
    uint64_t base = (uint64_t)loaded_image->image_base;
    for (int i = 0; i < 16; i++) {
        hexbuf[15 - i] = "0123456789ABCDEF"[base >> (i * 4) & 0xF];
    }
    hexbuf[16] = 0;
    console_print_ascii(hexbuf);
    console_print_ascii("\r\n");

    /* ---- 2. Open the ESP filesystem ---- */
    /* Use the device handle from the loaded image */
    efi_simple_file_system_protocol_t *fs = NULL;

    efi_guid_t fs_guid = SIMPLE_FS_GUID;
    status = handle_protocol(loaded_image->device_handle, &fs_guid,
                             (void **)&fs);
    if (status != EFI_SUCCESS) {
        console_print_ascii("Error: cannot open ESP filesystem\r\n");
        return status;
    }

    efi_file_protocol_t *root = NULL;
    status = fs->open_volume(fs, &root);
    if (status != EFI_SUCCESS) {
        console_print_ascii("Error: cannot open ESP root\r\n");
        return status;
    }

    console_print_ascii("ESP filesystem opened\r\n");

    /* ---- 3. Read mach_kernel ---- */
    void *kernel_buf = NULL;
    uint64_t kernel_size = 0;

    char16_t kernel_name[] = {
        '\\', 'E', 'F', 'I', '\\', 'H', 'A', 'K', 'I', 'O', 'S', '\\',
        'm', 'a', 'c', 'h', '_', 'k', 'e', 'r', 'n', 'e', 'l', 0
    };

    status = hakios_read_file(root, kernel_name, &kernel_buf, &kernel_size);
    if (status != EFI_SUCCESS) {
        console_print_ascii("Error: cannot read mach_kernel\r\n");
        console_print_ascii("Place mach_kernel at \\EFI\\HAKIOS\\mach_kernel\r\n");
        root->close(root);
        return status;
    }

    console_print_ascii("mach_kernel loaded: ");
    /* Print kernel size */
    for (int i = 0; i < 16; i++) {
        hexbuf[15 - i] = "0123456789ABCDEF"[(kernel_size >> (i * 4)) & 0xF];
    }
    hexbuf[16] = 0;
    console_print_ascii(hexbuf);
    console_print_ascii(" bytes\r\n");

    /* ---- 4. Read kernel command line ---- */
    void *cmdline_buf = NULL;
    uint64_t cmdline_size = 0;

    char16_t cmdline_name[] = {
        '\\', 'E', 'F', 'I', '\\', 'H', 'A', 'K', 'I', 'O', 'S', '\\',
        'c', 'm', 'd', 'l', 'i', 'n', 'e', '.', 't', 'x', 't', 0
    };

    status = hakios_read_file(root, cmdline_name, &cmdline_buf, &cmdline_size);
    if (status == EFI_SUCCESS) {
        console_print_ascii("Command line loaded\r\n");
    } else {
        console_print_ascii("No cmdline.txt, using defaults\r\n");
        /* Use default command line */
        static char default_cmdline[] = "cpus=2 display=1 input=1 disk=1 net=1 serial=1";
        cmdline_buf = default_cmdline;
        cmdline_size = sizeof(default_cmdline);
    }

    root->close(root);

    /* ---- 5. Get EFI memory map ---- */
    void *mem_map = NULL;
    uint64_t map_size = 0;
    uint64_t map_key = 0;
    uint64_t desc_size = 0;

    status = hakios_get_memory_map(&mem_map, &map_size, &map_key, &desc_size);
    if (status != EFI_SUCCESS) {
        console_print_ascii("Error: cannot get memory map\r\n");
        return status;
    }

    console_print_ascii("Memory map obtained\r\n");

    /* ---- 6. Fill BootArgs ---- */
    /* Allocate BootArgs structure */
    boot_args_t *boot_args = NULL;
    status = g_st->boot_services->efi_allocate_pool(
        EFI_LOADER_DATA, sizeof(boot_args_t), (void **)&boot_args);
    if (status != EFI_SUCCESS) {
        console_print_ascii("Error: cannot allocate boot args\r\n");
        return status;
    }

    hakios_memset(boot_args, 0, sizeof(boot_args_t));

    boot_args->revision = 2;
    boot_args->version = 2;
    boot_args->efi_mode = 0; /* 0 = 32-bit UEFI, 1 = 64-bit UEFI */
    boot_args->command_line = (uint32_t)(uintptr_t)cmdline_buf;
    boot_args->command_line_length = (uint32_t)cmdline_size;
    boot_args->memory_map = (uint32_t)(uintptr_t)mem_map;
    boot_args->memory_map_size = (uint32_t)map_size;
    boot_args->memory_map_descriptor_size = (uint32_t)desc_size;
    boot_args->memory_map_descriptor_version = 1;

    /* Video info: VGA text mode */
    boot_args->video_type = 0; /* 0 = text */
    boot_args->video_base_addr = 0xB8000;
    boot_args->video_row_bytes = 160; /* 80 * 2 */
    boot_args->video_height = 25;
    boot_args->video_width = 80;
    boot_args->video_depth = 4; /* 16 colors */

    /* EFI runtime services */
    boot_args->efi_system_table = (uint32_t)(uintptr_t)system_table;
    boot_args->efi_runtime_services = (uint32_t)(uintptr_t)system_table->runtime_services;

    console_print_ascii("BootArgs filled\r\n");

    /* ---- 7. Exit Boot Services ---- */
    console_print_ascii("Exiting UEFI boot services...\r\n");

    status = g_st->boot_services->efi_exit_boot_services(image_handle, map_key);
    if (status != EFI_SUCCESS) {
        /* Retry: the memory map may have changed */
        status = hakios_get_memory_map(&mem_map, &map_size, &map_key, &desc_size);
        if (status != EFI_SUCCESS)
            return status;

        status = g_st->boot_services->efi_exit_boot_services(image_handle, map_key);
        if (status != EFI_SUCCESS)
            return status;
    }

    /* ---- 8. Jump to kernel ---- */
    /* The XNU kernel entry point is at the start of the mach_kernel image */
    typedef void (*kernel_entry_t)(boot_args_t *);
    kernel_entry_t kernel_entry = (kernel_entry_t)(uintptr_t)kernel_buf;

    /* Call the kernel */
    kernel_entry(boot_args);

    /* Should never return */
    while (1)
        ;

    return EFI_SUCCESS;
}
