/* ============================================================================
 * Archivo: video.s
 * Descripción: Controlador I2C0 Bare-Metal, inicialización de pantalla OLED
 *              SSD1306 (128x64), Framebuffer de 1024 bytes en RAM y motor
 *              gráfico de sprites y caracteres (Font Mapping).
 * Estándar: AAPCS (Preservación de r4-r7, lr y pila alineada a 8 bytes)
 * ============================================================================ */

.syntax unified
.cpu cortex-m0plus
.thumb

/* --- Direcciones Base y Registros MMIO --- */
.equ RESETS_RESET_CLR,  0x4000F000
.equ RESETS_DONE,       0x4000C008

.equ IO_GPIO4_CTRL,     0x40014024      /* GP4 = I2C0 SDA (Func 3) */
.equ IO_GPIO5_CTRL,     0x4001402C      /* GP5 = I2C0 SCL (Func 3) */
.equ PAD_GPIO4,         0x4001C014      /* Pad GP4 */
.equ PAD_GPIO5,         0x4001C018      /* Pad GP5 */

.equ I2C0_BASE,         0x40044000      /* Base de I2C0 (DW_apb_i2c) */
.equ I2C_CON,           0x00            /* Control Register */
.equ I2C_TAR,           0x04            /* Target Address Register */
.equ I2C_DATA_CMD,      0x10            /* Data Buffer and Command Register */
.equ I2C_FS_SCL_HCNT,   0x1C            /* Fast Mode SCL High Count */
.equ I2C_FS_SCL_LCNT,   0x20            /* Fast Mode SCL Low Count */
.equ I2C_CLR_TX_ABRT,   0x54            /* Clear TX Abort Register */
.equ I2C_ENABLE,        0x6C            /* Enable Register */
.equ I2C_STATUS,        0x70            /* Status Register */
.equ I2C_FS_SPKLEN_ADDR,0x400440A0      /* Spike Suppression Limit (offset 0xA0) */

.equ OLED_I2C_ADDR,     0x3C            /* Dirección I2C estándar del SSD1306 */

/* --- Framebuffer en Memoria RAM (128x64 píxeles = 1024 bytes) --- */
.section .bss
.align 2
.global framebuffer
framebuffer:
    .space 1024

/* --- Código del Motor de Video --- */
.section .text
.align 2

.global video_init
.global fb_clear
.global fb_draw_pixel
.global fb_draw_hline
.global fb_draw_sprite
.global fb_draw_char
.global fb_draw_string
.global fb_draw_num3
.global oled_flush

/* ----------------------------------------------------------------------------
 * Subrutina: video_init
 * Configura I2C0 en GP4/GP5 a ~100 kHz e inicializa el controlador SSD1306.
 * ---------------------------------------------------------------------------- */
.thumb_func
video_init:
    push {r4, r5, r6, lr}               /* 4 registros = 16 bytes (alineado a 8 bytes) */

    /* 1. Sacar de reset I2C0 (bit 3), IO_BANK0 (bit 5), PADS_BANK0 (bit 8) */
    ldr r0, =RESETS_RESET_CLR
    ldr r1, =0x00000128                 /* (1<<8) | (1<<5) | (1<<3) */
    str r1, [r0, #0]
    ldr r0, =RESETS_DONE
1:
    ldr r2, [r0, #0]
    ands r2, r1
    cmp r2, r1
    bne 1b

    /* 2. Configurar Pads GP4 y GP5 con Pull-Up (PUE), Input Enable (IE) y Schmitt */
    ldr r0, =PAD_GPIO4
    movs r1, #0x5A                      /* IE (0x40) | DRIVE 4mA (0x10) | PUE (0x08) | SCHMITT (0x02) */
    str r1, [r0, #0]
    ldr r0, =PAD_GPIO5
    str r1, [r0, #0]

    /* 3. Seleccionar Función 3 (I2C0) en GP4 (SDA) y GP5 (SCL) */
    movs r1, #3
    ldr r0, =IO_GPIO4_CTRL
    str r1, [r0, #0]
    ldr r0, =IO_GPIO5_CTRL
    str r1, [r0, #0]

    /* 4. Configurar periférico I2C0 como Maestro en Fast Mode */
    ldr r4, =I2C0_BASE
    movs r0, #0
    str r0, [r4, #I2C_ENABLE]           /* Deshabilitar I2C0 antes de configurar */

    /* I2C_CON: MASTER_MODE(1) | SPEED_FAST(2<<1) | RESTART_EN(1<<5) | SLAVE_DISABLE(1<<6) = 0x65 */
    movs r0, #0x65
    str r0, [r4, #I2C_CON]

    /* Tiempos SCL cercanos a 370 kHz con clk_sys = 125 MHz */
    movs r0, #150
    str r0, [r4, #I2C_FS_SCL_HCNT]
    movs r0, #190
    str r0, [r4, #I2C_FS_SCL_LCNT]

    ldr r0, =I2C_FS_SPKLEN_ADDR
    movs r1, #4
    str r1, [r0, #0]

    /* Dirección esclava del OLED: 0x3C */
    movs r0, #OLED_I2C_ADDR
    str r0, [r4, #I2C_TAR]

    /* Habilitar I2C0 */
    movs r0, #1
    str r0, [r4, #I2C_ENABLE]

    /* 5. Enviar secuencia de comandos de inicialización al SSD1306 */
    ldr r5, =oled_init_cmds
    movs r6, #28                        /* Bytes de comandos y parámetros */
init_cmd_loop:
    ldrb r0, [r5, #0]
    bl oled_send_cmd
    adds r5, r5, #1
    subs r6, r6, #1
    bne init_cmd_loop

    /* 6. Limpiar Framebuffer y volcar a pantalla */
    bl fb_clear
    bl oled_flush

    pop {r4, r5, r6, pc}

/* ----------------------------------------------------------------------------
 * Subrutina interna: i2c_wait_tfnf
 * Espera a que el FIFO de transmisión de I2C0 tenga espacio (TFNF, bit 1 = 1).
 * ---------------------------------------------------------------------------- */
.thumb_func
i2c_wait_tfnf:
    ldr r2, =I2C0_BASE
    movs r3, #2                         /* Bit 1 = TFNF */
1:
    ldr r1, [r2, #I2C_CLR_TX_ABRT]      /* Limpiar posibles aborts */
    ldr r1, [r2, #I2C_STATUS]
    ands r1, r3
    beq 1b
    bx lr

/* ----------------------------------------------------------------------------
 * Subrutina interna: i2c_wait_idle
 * Espera a que el FIFO TX se vacíe (TFE, bit 2 = 1) y el bus quede libre (bit 5 = 0).
 * ---------------------------------------------------------------------------- */
.thumb_func
i2c_wait_idle:
    ldr r2, =I2C0_BASE
1:
    ldr r1, [r2, #I2C_STATUS]
    movs r3, #4                         /* Bit 2 = TFE */
    ands r3, r1
    beq 1b
    movs r3, #0x20                      /* Bit 5 = MST_ACTIVITY */
    ands r3, r1
    bne 1b
    bx lr

/* ----------------------------------------------------------------------------
 * Subrutina: oled_send_cmd
 * Envía un comando de 1 byte (r0) al SSD1306 por I2C0 [0x00, cmd | STOP].
 * ---------------------------------------------------------------------------- */
.thumb_func
oled_send_cmd:
    push {r4, lr}
    movs r4, r0                         /* Guardar comando en r4 */

    bl i2c_wait_tfnf
    ldr r2, =I2C0_BASE
    movs r0, #0x00                      /* Control byte: Co=0, D/C#=0 (Comando) */
    str r0, [r2, #I2C_DATA_CMD]

    bl i2c_wait_tfnf
    ldr r2, =I2C0_BASE
    movs r0, #1
    lsls r0, r0, #9                     /* Bit 9 = STOP (0x200) */
    orrs r0, r4
    str r0, [r2, #I2C_DATA_CMD]

    bl i2c_wait_idle
    pop {r4, pc}

/* ----------------------------------------------------------------------------
 * Subrutina: oled_flush
 * Transfiere masivamente los 1024 bytes del Framebuffer en RAM al OLED SSD1306.
 * ---------------------------------------------------------------------------- */
.thumb_func
oled_flush:
    push {r4, r5, r6, lr}

    /* 1. Fijar ventana de columnas (0..127) y páginas (0..7) */
    movs r0, #0x21                      /* Set Column Address */
    bl oled_send_cmd
    movs r0, #0x00                      /* Columna inicial = 0 */
    bl oled_send_cmd
    movs r0, #0x7F                      /* Columna final = 127 */
    bl oled_send_cmd

    movs r0, #0x22                      /* Set Page Address */
    bl oled_send_cmd
    movs r0, #0x00                      /* Página inicial = 0 */
    bl oled_send_cmd
    movs r0, #0x07                      /* Página final = 7 */
    bl oled_send_cmd

    /* 2. Enviar los 1024 bytes en 8 ráfagas de 128 bytes por I2C0 */
    ldr r4, =framebuffer
    movs r5, #8                         /* 8 páginas */

flush_page_loop:
    bl i2c_wait_tfnf
    ldr r2, =I2C0_BASE
    movs r0, #0x40                      /* Control byte: Co=0, D/C#=1 (Datos de RAM gráfica) */
    str r0, [r2, #I2C_DATA_CMD]

    movs r6, #128                       /* 128 columnas por página */
flush_byte_loop:
    bl i2c_wait_tfnf
    ldrb r0, [r4, #0]
    adds r4, r4, #1

    /* Si es el último byte de la ráfaga (r6 == 1), agregar bit STOP (0x200) */
    cmp r6, #1
    bne 1f
    movs r1, #1
    lsls r1, r1, #9                     /* 0x200 = STOP */
    orrs r0, r1
1:
    ldr r2, =I2C0_BASE
    str r0, [r2, #I2C_DATA_CMD]

    subs r6, r6, #1
    bne flush_byte_loop

    bl i2c_wait_idle
    subs r5, r5, #1
    bne flush_page_loop

    pop {r4, r5, r6, pc}

.ltorg

.ltorg

/* ----------------------------------------------------------------------------
 * Subrutina: fb_clear
 * Limpia los 1024 bytes del Framebuffer en RAM escribiendo ceros en bloques de 32 bits.
 * ---------------------------------------------------------------------------- */
.thumb_func
fb_clear:
    ldr r0, =framebuffer
    movs r1, #0
    movs r2, #1
    lsls r2, r2, #8                     /* 256 palabras de 32 bits = 1024 bytes */
1:
    str r1, [r0, #0]
    adds r0, r0, #4
    subs r2, r2, #1
    bne 1b
    bx lr

/* ----------------------------------------------------------------------------
 * Subrutina: fb_draw_pixel
 * Enciende un píxel en el Framebuffer en las coordenadas (r0 = x, r1 = y).
 * Verifica límites (0 <= x < 128, 0 <= y < 64).
 * ---------------------------------------------------------------------------- */
.thumb_func
fb_draw_pixel:
    cmp r0, #128
    bhs pix_exit                        /* Descartar si x >= 128 (unsigned) */
    cmp r1, #64
    bhs pix_exit                        /* Descartar si y >= 64 (unsigned) */

    /* Índice en Framebuffer = ((y >> 3) << 7) + x */
    movs r2, r1
    lsrs r2, r2, #3                     /* r2 = página (y / 8) */
    lsls r2, r2, #7                     /* r2 = página * 128 */
    adds r2, r2, r0                     /* r2 = offset del byte */

    ldr r3, =framebuffer
    adds r3, r3, r2                     /* r3 = &framebuffer[offset] */

    /* Máscara de bit = 1 << (y & 7) */
    movs r2, #7
    ands r1, r2                         /* r1 = y & 7 */
    movs r2, #1
    lsls r2, r1                         /* r2 = máscara del píxel */

    ldrb r0, [r3, #0]
    orrs r0, r2
    strb r0, [r3, #0]

pix_exit:
    bx lr

.ltorg

/* ----------------------------------------------------------------------------
 * Subrutina: fb_draw_hline
 * Dibuja una línea horizontal completa de X=0 a X=127 en la fila Y = r0.
 * ---------------------------------------------------------------------------- */
.thumb_func
fb_draw_hline:
    push {r3, r4, r5, lr}
    movs r4, #0                         /* x = 0 */
    movs r5, r0                         /* y */
1:
    movs r0, r4
    movs r1, r5
    bl fb_draw_pixel
    adds r4, r4, #1
    cmp r4, #128
    blt 1b
    pop {r3, r4, r5, pc}

/* ----------------------------------------------------------------------------
 * Subrutina: fb_draw_sprite
 * Dibuja un sprite de 8x8 píxeles en cualquier coordenada (X, Y) del Framebuffer.
 * Parámetros: r0 = X, r1 = Y, r2 = puntero al bitmap de 8 bytes (1 byte por fila).
 * ---------------------------------------------------------------------------- */
.thumb_func
fb_draw_sprite:
    push {r3, r4, r5, r6, r7, lr}       /* 6 registros = 24 bytes (alineado a 8 bytes) */
    movs r4, r0                         /* r4 = base X */
    movs r5, r1                         /* r5 = base Y */
    movs r6, r2                         /* r6 = puntero al sprite */
    movs r7, #0                         /* r7 = fila actual (0..7) */

sprite_row_loop:
    ldrb r3, [r6, r7]                   /* r3 = byte de la fila actual */
    mov r2, r3                          /* Guardar byte de fila */
    movs r3, #0                         /* r3 = columna actual (0..7) */

sprite_col_loop:
    mov r0, r2
    movs r1, #0x80
    lsrs r1, r3                         /* Máscara: bit (7 - col) */
    ands r0, r1
    beq sprite_skip_pix

    push {r2, r3}
    adds r0, r4, r3                     /* X + col */
    adds r1, r5, r7                     /* Y + row */
    bl fb_draw_pixel
    pop {r2, r3}

sprite_skip_pix:
    adds r3, r3, #1
    cmp r3, #8
    blt sprite_col_loop

    adds r7, r7, #1
    cmp r7, #8
    blt sprite_row_loop

    pop {r3, r4, r5, r6, r7, pc}

/* ----------------------------------------------------------------------------
 * Subrutina: fb_draw_char
 * Dibuja un carácter ASCII en (r0 = X, r1 = Y, r2 = carácter ASCII) usando font_table.
 * ---------------------------------------------------------------------------- */
.thumb_func
fb_draw_char:
    push {r4, lr}
    movs r3, #0                         /* Índice por defecto = 0 (espacio) */

    cmp r2, #' '
    beq char_found
    cmp r2, #':'
    bne 1f
    movs r3, #37                        /* ':' está en el índice 37 */
    b char_found
1:
    cmp r2, #'-'
    bne 2f
    movs r3, #38                        /* '-' está en el índice 38 */
    b char_found
2:
    cmp r2, #'0'
    blt char_found
    cmp r2, #'9'
    bgt 3f
    movs r3, #'0'
    subs r3, r2, r3
    adds r3, r3, #1                     /* '0'..'9' -> índices 1..10 */
    b char_found
3:
    cmp r2, #'A'
    blt char_found
    cmp r2, #'Z'
    bgt char_found
    movs r3, #'A'
    subs r3, r2, r3
    adds r3, r3, #11                    /* 'A'..'Z' -> índices 11..36 */

char_found:
    lsls r3, r3, #3                     /* Multiplicar índice por 8 bytes */
    ldr r2, =font_table
    adds r2, r2, r3                     /* r2 = puntero al glifo de 8x8 */
    bl fb_draw_sprite
    pop {r4, pc}

/* ----------------------------------------------------------------------------
 * Subrutina: fb_draw_string
 * Dibuja una cadena terminada en NULL en (r0 = X, r1 = Y, r2 = puntero a string).
 * ---------------------------------------------------------------------------- */
.thumb_func
fb_draw_string:
    push {r4, r5, r6, lr}
    movs r4, r0                         /* X actual */
    movs r5, r1                         /* Y fijo */
    movs r6, r2                         /* Puntero al string */
1:
    ldrb r2, [r6, #0]
    cmp r2, #0
    beq 2f
    movs r0, r4
    movs r1, r5
    bl fb_draw_char
    adds r4, r4, #8                     /* Avanzar 8 píxeles en X */
    adds r6, r6, #1
    b 1b
2:
    pop {r4, r5, r6, pc}

/* ----------------------------------------------------------------------------
 * Subrutina: fb_draw_num3
 * Convierte un entero (0..999) en 3 dígitos decimales sin usar división por
 * hardware (inexistente en Cortex-M0+) y los dibuja en (r0 = X, r1 = Y, r2 = valor).
 * ---------------------------------------------------------------------------- */
.thumb_func
fb_draw_num3:
    push {r3, r4, r5, r6, r7, lr}
    movs r4, r0                         /* X */
    movs r5, r1                         /* Y */
    movs r6, r2                         /* Valor restante */

    /* Calcular centenas por sustracción sucesiva */
    movs r7, #'0'
1:
    cmp r6, #100
    blt 2f
    subs r6, r6, #100
    adds r7, r7, #1
    b 1b
2:
    movs r0, r4
    movs r1, r5
    movs r2, r7
    bl fb_draw_char
    adds r4, r4, #8

    /* Calcular decenas */
    movs r7, #'0'
3:
    cmp r6, #10
    blt 4f
    subs r6, r6, #10
    adds r7, r7, #1
    b 3b
4:
    movs r0, r4
    movs r1, r5
    movs r2, r7
    bl fb_draw_char
    adds r4, r4, #8

    /* Unidades */
    movs r2, #'0'
    adds r2, r2, r6
    movs r0, r4
    movs r1, r5
    bl fb_draw_char

    pop {r3, r4, r5, r6, r7, pc}

.ltorg

/* --- Tablas de Solo Lectura: Inicialización OLED y Mapa de Caracteres 8x8 --- */
.section .rodata
.align 2

oled_init_cmds:
    .byte 0xAE          /* Display OFF */
    .byte 0x20, 0x00    /* Memory Addressing Mode: Horizontal Addressing Mode */
    .byte 0xB0          /* Page Start Address = 0 */
    .byte 0xC8          /* COM Output Scan Direction: Remapped */
    .byte 0x00          /* Low Column Address = 0 */
    .byte 0x10          /* High Column Address = 0 */
    .byte 0x40          /* Start Line Address = 0 */
    .byte 0x81, 0xCF    /* Contrast Control = 0xCF */
    .byte 0xA1          /* Segment Re-map: column 127 mapped to SEG0 */
    .byte 0xA6          /* Normal Display (not inverted) */
    .byte 0xA8, 0x3F    /* Multiplex Ratio = 63 (64 linhas) */
    .byte 0xA4          /* Output follows RAM content */
    .byte 0xD3, 0x00    /* Display Offset = 0 */
    .byte 0xD5, 0x80    /* Display Clock Divide Ratio */
    .byte 0xD9, 0xF1    /* Pre-charge Period */
    .byte 0xDA, 0x12    /* COM Pins Hardware Configuration */
    .byte 0xDB, 0x40    /* VCOMH Deselect Level */
    .byte 0x8D, 0x14    /* Charge Pump Enable (0x14) */
    .byte 0xAF          /* Display ON */

.align 2
font_table:
    /* 0: ' ' (Espacio) */
    .byte 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
    /* 1..10: '0'..'9' */
    .byte 0x3C, 0x66, 0x6E, 0x76, 0x66, 0x66, 0x3C, 0x00 /* 0 */
    .byte 0x18, 0x38, 0x18, 0x18, 0x18, 0x18, 0x7E, 0x00 /* 1 */
    .byte 0x3C, 0x66, 0x06, 0x0C, 0x18, 0x30, 0x7E, 0x00 /* 2 */
    .byte 0x3C, 0x66, 0x06, 0x1C, 0x06, 0x66, 0x3C, 0x00 /* 3 */
    .byte 0x0C, 0x1C, 0x3C, 0x6C, 0x7E, 0x0C, 0x0C, 0x00 /* 4 */
    .byte 0x7E, 0x60, 0x7C, 0x06, 0x06, 0x66, 0x3C, 0x00 /* 5 */
    .byte 0x1C, 0x30, 0x60, 0x7C, 0x66, 0x66, 0x3C, 0x00 /* 6 */
    .byte 0x7E, 0x06, 0x0C, 0x18, 0x30, 0x30, 0x30, 0x00 /* 7 */
    .byte 0x3C, 0x66, 0x66, 0x3C, 0x66, 0x66, 0x3C, 0x00 /* 8 */
    .byte 0x3C, 0x66, 0x66, 0x3E, 0x06, 0x0C, 0x38, 0x00 /* 9 */
    /* 11..36: 'A'..'Z' */
    .byte 0x18, 0x3C, 0x66, 0x66, 0x7E, 0x66, 0x66, 0x00 /* A */
    .byte 0x7C, 0x66, 0x66, 0x7C, 0x66, 0x66, 0x7C, 0x00 /* B */
    .byte 0x3C, 0x66, 0x60, 0x60, 0x60, 0x66, 0x3C, 0x00 /* C */
    .byte 0x78, 0x6C, 0x66, 0x66, 0x66, 0x6C, 0x78, 0x00 /* D */
    .byte 0x7E, 0x60, 0x60, 0x7C, 0x60, 0x60, 0x7E, 0x00 /* E */
    .byte 0x7E, 0x60, 0x60, 0x7C, 0x60, 0x60, 0x60, 0x00 /* F */
    .byte 0x3C, 0x66, 0x60, 0x6E, 0x66, 0x66, 0x3C, 0x00 /* G */
    .byte 0x66, 0x66, 0x66, 0x7E, 0x66, 0x66, 0x66, 0x00 /* H */
    .byte 0x3C, 0x18, 0x18, 0x18, 0x18, 0x18, 0x3C, 0x00 /* I */
    .byte 0x1E, 0x0C, 0x0C, 0x0C, 0x0C, 0x6C, 0x38, 0x00 /* J */
    .byte 0x66, 0x6C, 0x78, 0x70, 0x78, 0x6C, 0x66, 0x00 /* K */
    .byte 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x7E, 0x00 /* L */
    .byte 0x63, 0x77, 0x7F, 0x6B, 0x63, 0x63, 0x63, 0x00 /* M */
    .byte 0x66, 0x76, 0x7E, 0x7E, 0x6E, 0x66, 0x66, 0x00 /* N */
    .byte 0x3C, 0x66, 0x66, 0x66, 0x66, 0x66, 0x3C, 0x00 /* O */
    .byte 0x7C, 0x66, 0x66, 0x7C, 0x60, 0x60, 0x60, 0x00 /* P */
    .byte 0x3C, 0x66, 0x66, 0x66, 0x6A, 0x6C, 0x36, 0x00 /* Q */
    .byte 0x7C, 0x66, 0x66, 0x7C, 0x6C, 0x66, 0x66, 0x00 /* R */
    .byte 0x3C, 0x66, 0x60, 0x3C, 0x06, 0x66, 0x3C, 0x00 /* S */
    .byte 0x7E, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x00 /* T */
    .byte 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x3C, 0x00 /* U */
    .byte 0x66, 0x66, 0x66, 0x66, 0x66, 0x3C, 0x18, 0x00 /* V */
    .byte 0x63, 0x63, 0x63, 0x6B, 0x7F, 0x77, 0x63, 0x00 /* W */
    .byte 0x66, 0x66, 0x3C, 0x18, 0x3C, 0x66, 0x66, 0x00 /* X */
    .byte 0x66, 0x66, 0x66, 0x3C, 0x18, 0x18, 0x18, 0x00 /* Y */
    .byte 0x7E, 0x06, 0x0C, 0x18, 0x30, 0x60, 0x7E, 0x00 /* Z */
    /* 37: ':' */
    .byte 0x00, 0x18, 0x18, 0x00, 0x18, 0x18, 0x00, 0x00
    /* 38: '-' */
    .byte 0x00, 0x00, 0x00, 0x7E, 0x00, 0x00, 0x00, 0x00