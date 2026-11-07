/* ============================================================================
 * Archivo: inputs.s
 * Descripción: Acceso directo a registros del ADC (GP26=X, GP27=Y) y GPIO (GP22=Z).
 * Estándar: AAPCS (Preservación de registros y uso de pila)
 * ============================================================================ */

.syntax unified
.cpu cortex-m0plus
.thumb

/* --- Direcciones Base y Registros MMIO --- */
.equ CLK_ADC_CTRL,      0x40008060      /* Control de reloj del ADC (Bit 11 = ENABLE) */
.equ RESETS_RESET_CLR,  0x4000F000      /* Atomic Clear para RESETS_RESET */
.equ RESETS_DONE,       0x4000C008      /* Estado de periféricos fuera de reset */

.equ IO_GPIO22_CTRL,    0x400140B4      /* IO_BANK0: Control de GP22 (0x40014000 + 22*8 + 4) */
.equ PAD_GPIO22,        0x4001C05C      /* PADS_BANK0: Pad de GP22 (0x4001C000 + 22*4 + 4) */
.equ PAD_GPIO26,        0x4001C06C      /* PADS_BANK0: Pad de GP26 (ADC0) */
.equ PAD_GPIO27,        0x4001C070      /* PADS_BANK0: Pad de GP27 (ADC1) */

.equ SIO_GPIO_IN,       0xD0000004      /* Registro de entrada de pines GPIO */
.equ SIO_GPIO_OE_CLR,   0xD0000028      /* Limpiar Output Enable (configurar como entrada) */

.equ ADC_BASE,          0x4004C000      /* Base del periférico ADC */
.equ ADC_CS,            0x00            /* Control and Status */
.equ ADC_RESULT,        0x04            /* Resultado de conversión de 12 bits (0..4095) */

/* --- Estado previo del botón para detección de flanco --- */
.section .bss
.align 2
previous_button_z_state:
    .space 4                            /* Guarda el estado anterior de GP22 */

.section .text
.align 2

.global inputs_init
.global read_adc_x
.global read_adc_y
.global read_btn_z_pressed

/* ----------------------------------------------------------------------------
 * Subrutina: inputs_init
 * Inicializa relojes, saca de reset ADC/IO_BANK0/PADS_BANK0 y configura pines.
 * ---------------------------------------------------------------------------- */
.thumb_func
inputs_init:
    push {r4, lr}

    /* 1. Habilitar reloj del ADC (Bit 11 en CLK_ADC_CTRL) */
    ldr r0, =CLK_ADC_CTRL
    ldr r1, [r0, #0]
    movs r2, #1
    lsls r2, r2, #11
    orrs r1, r2
    str r1, [r0, #0]

    /* 2. Sacar de reset: ADC (bit 0), IO_BANK0 (bit 5) y PADS_BANK0 (bit 8) */
    ldr r0, =RESETS_RESET_CLR
    ldr r1, =0x00000121                 /* (1<<8) | (1<<5) | (1<<0) */
    str r1, [r0, #0]
    ldr r0, =RESETS_DONE
1:
    ldr r2, [r0, #0]
    ands r2, r1
    cmp r2, r1
    bne 1b

    /* 3. Configurar GP22 (Botón Z) como función SIO (5) y entrada con Pull-Up */
    ldr r0, =IO_GPIO22_CTRL
    movs r1, #5                         /* FUNCSEL 5 = SIO */
    str r1, [r0, #0]

    ldr r0, =PAD_GPIO22
    movs r1, #0x4A                      /* IE (bit 6) | PUE (bit 3) | SCHMITT (bit 1) */
    str r1, [r0, #0]

    ldr r0, =SIO_GPIO_OE_CLR
    movs r1, #1
    lsls r1, r1, #22                    /* GP22 como entrada */
    str r1, [r0, #0]

    /* 4. Configurar Pads de GP26 y GP27 para entrada analógica pura */
    ldr r0, =PAD_GPIO26
    movs r1, #0x80                      /* OD=1 (Output Disable), IE=0 (Input Disable) */
    str r1, [r0, #0]
    ldr r0, =PAD_GPIO27
    str r1, [r0, #0]

    /* 5. Encender el periférico ADC (Bit 0 EN = 1 en ADC_CS) */
    ldr r0, =ADC_BASE
    movs r1, #1
    str r1, [r0, #ADC_CS]

    /* 6. Inicializar estado previo del botón en 1 (no presionado, activo en bajo) */
    ldr r0, =previous_button_z_state
    movs r1, #1
    str r1, [r0, #0]

    pop {r4, pc}

/* ----------------------------------------------------------------------------
 * Subrutina: read_adc_x
 * Lee el canal 0 del ADC (GP26) y devuelve un desplazamiento en píxeles (-2 a +2).
 * Retorno: r0 = delta X (-2, -1, 0, +1, +2)
 * ---------------------------------------------------------------------------- */
.thumb_func
read_adc_x:
    push {r4, lr}

    ldr r0, =ADC_BASE
    /* Seleccionar AINSEL = 0 (GP26), START_ONCE (bit 2) y EN (bit 0) -> 0x0005 */
    movs r1, #5
    str r1, [r0, #ADC_CS]

    /* Esperar a que el bit READY (bit 8 = 0x100) sea 1 */
    movs r2, #1
    lsls r2, r2, #8
1:
    ldr r1, [r0, #ADC_CS]
    ands r1, r2
    beq 1b

    /* Leer valor de 12 bits (0..4095, centro ~2048) */
    ldr r1, [r0, #ADC_RESULT]
    bl adc_to_delta                     /* Convierte r1 en velocidad (-2..+2) en r0 */

    pop {r4, pc}

/* ----------------------------------------------------------------------------
 * Subrutina: read_adc_y
 * Lee el canal 1 del ADC (GP27) y devuelve un desplazamiento en píxeles (-2 a +2).
 * Retorno: r0 = delta Y (-2, -1, 0, +1, +2)
 * ---------------------------------------------------------------------------- */
.thumb_func
read_adc_y:
    push {r4, lr}

    ldr r0, =ADC_BASE
    /* Seleccionar AINSEL = 1 (GP27 -> bit 12), START_ONCE (bit 2), EN (bit 0) -> 0x1005 */
    ldr r1, =0x00001005
    str r1, [r0, #ADC_CS]

    /* Esperar a que el bit READY (bit 8 = 0x100) sea 1 */
    movs r2, #1
    lsls r2, r2, #8
1:
    ldr r1, [r0, #ADC_CS]
    ands r1, r2
    beq 1b

    /* Leer valor de 12 bits (0..4095) */
    ldr r1, [r0, #ADC_RESULT]
    bl adc_to_delta

    pop {r4, pc}

/* ----------------------------------------------------------------------------
 * Subrutina auxiliar: adc_to_delta
 * Convierte lectura ADC (0..4095) en r1 a delta (-2, -1, 0, +1, +2) en r0.
 * ---------------------------------------------------------------------------- */
.thumb_func
adc_to_delta:
    ldr r2, =600
    cmp r1, r2
    blt delta_neg2                      /* < 600: inclinación fuerte (-2) */

    ldr r2, =1500
    cmp r1, r2
    blt delta_neg1                      /* < 1500: inclinación suave (-1) */

    ldr r2, =3500
    cmp r1, r2
    bgt delta_pos2                      /* > 3500: inclinación fuerte (+2) */

    ldr r2, =2600
    cmp r1, r2
    bgt delta_pos1                      /* > 2600: inclinación suave (+1) */

    movs r0, #0                         /* Zona muerta central (1500..2600) */
    bx lr

delta_neg2:
    movs r0, #2
    negs r0, r0                         /* r0 = -2 */
    bx lr
delta_neg1:
    movs r0, #1
    negs r0, r0                         /* r0 = -1 */
    bx lr
delta_pos1:
    movs r0, #1
    bx lr
delta_pos2:
    movs r0, #2
    bx lr

/* ----------------------------------------------------------------------------
 * Subrutina: read_btn_z_pressed
 * Detecta flanco de bajada en el botón Z del joystick (GP22, activo en bajo).
 * Retorno: r0 = 1 si se acaba de pulsar el botón, r0 = 0 en caso contrario.
 * ---------------------------------------------------------------------------- */
.thumb_func
read_btn_z_pressed:
    push {r4, lr}

    ldr r0, =SIO_GPIO_IN
    ldr r1, [r0, #0]
    lsrs r1, r1, #22
    movs r2, #1
    ands r1, r2                         /* r1 = estado actual de GP22 (0 = presionado, 1 = suelto) */

    ldr r2, =previous_button_z_state
    ldr r3, [r2, #0]                    /* r3 = estado anterior */
    str r1, [r2, #0]                    /* Actualizar estado anterior */

    /* Ocurre flanco de bajada si antes era 1 (suelto) y ahora es 0 (presionado) */
    movs r0, #0
    cmp r3, #1
    bne 1f
    cmp r1, #0
    bne 1f
    movs r0, #1                         /* ¡Botón pulsado! */
1:
    pop {r4, pc}

.ltorg