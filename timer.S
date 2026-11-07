/* ============================================================================
 * Archivo: timer.s
 * Descripción: Control del Timer por Hardware (RP2040 TIMER ALARM1) e
 *              interrupciones mediante NVIC y registro VTOR (Cortex-M0+).
 * Frecuencia de refresco: 33,333 us por tick (~30.00 FPS)
 * Estándar: AAPCS (Preservación de r4-r7, lr y pila alineada a 8 bytes)
 * ============================================================================ */

.syntax unified
.cpu cortex-m0plus
.thumb

/* --- Direcciones Base de Registros MMIO --- */
.equ RESETS_RESET_CLR,  0x4000F000      /* Atomic Clear para RESETS_RESET */
.equ RESETS_DONE,       0x4000C008      /* Estado de periféricos fuera de reset */
.equ TIMER_BASE,        0x40054000      /* Base del Hardware Timer (1 MHz / 1 us) */
.equ TIMER_ALARM1,      0x14            /* Offset de ALARM1 */
.equ TIMER_ARMED,       0x20            /* Offset de ARMED (escribir 1 desarma) */
.equ TIMER_TIMERAWL,    0x28            /* Offset de lectura cruda de 32 bits (us) */
.equ TIMER_INTR,        0x34            /* Offset de limpieza de interrupción (W1C) */
.equ TIMER_INTE,        0x38            /* Offset de habilitación de interrupción */

.equ PPB_VTOR,          0xE000ED08      /* Vector Table Offset Register */
.equ NVIC_ISER,         0xE000E100      /* NVIC Interrupt Set-Enable Register */
.equ NVIC_ICER,         0xE000E180      /* NVIC Interrupt Clear-Enable Register */
.equ NVIC_ICPR,         0xE000E280      /* NVIC Interrupt Clear-Pending Register */

.equ VTOR_IRQ1_OFFSET,  0x44            /* Offset de IRQ1 (TIMER_IRQ_1) = 0x40 + 1*4 */
.equ FRAME_PERIOD_US,   33333           /* 33,333 microsegundos = 30.0 FPS */

/* --- Variables de Estado del Temporizador en RAM --- */
.section .bss
.align 2
frame_tick_pending:
    .space 4                            /* Bandera volátil activada por la ISR */
physics_timer_enabled:
    .space 4                            /* 1 = Timer de físicas activo, 0 = Detenido */
.align 8
interrupt_vectors_ram:
    .space 192

/* --- Código del Módulo --- */
.section .text
.align 2

.global timer_init
.global timer_start
.global timer_stop
.global timer_check_and_clear_tick
.global timer1_isr

/* ----------------------------------------------------------------------------
 * Subrutina: timer_init
 * Instala el vector de interrupción en VTOR para IRQ1 y configura el NVIC.
 * Parámetros: Ninguno | Retorno: Ninguno
 * ---------------------------------------------------------------------------- */
.thumb_func
timer_init:
    push {r4, lr}                       /* Alineación de pila a 8 bytes (AAPCS) */

    /* 1. Asegurar que el periférico TIMER (bit 21) esté fuera de reset */
    ldr r0, =RESETS_RESET_CLR
    movs r1, #1
    lsls r1, r1, #21                    /* Máscara bit 21: TIMER */
    str r1, [r0, #0]
    ldr r0, =RESETS_DONE
1:
    ldr r2, [r0, #0]
    ands r2, r1
    beq 1b

    /* 2. Limpiar variables de estado en RAM */
    ldr r0, =frame_tick_pending
    movs r1, #0
    str r1, [r0, #0]
    ldr r0, =physics_timer_enabled
    str r1, [r0, #0]

    /* 3. Desarmar ALARM1 y limpiar cualquier interrupción previa */
    ldr r0, =TIMER_BASE
    movs r1, #2                         /* Bit 1 corresponde a ALARM1 */
    str r1, [r0, #TIMER_ARMED]
    str r1, [r0, #TIMER_INTR]

    /* 4. Registrar la dirección de timer1_isr en la tabla de vectores (VTOR) */
    ldr r0, =PPB_VTOR
    ldr r1, [r0, #0]
    ldr r2, =interrupt_vectors_ram
    movs r3, #48
copy_vector_table:
    ldr r0, [r1, #0]
    str r0, [r2, #0]
    adds r1, r1, #4
    adds r2, r2, #4
    subs r3, r3, #1
    bne copy_vector_table

    ldr r0, =timer1_isr
    movs r1, #1
    orrs r0, r1
    ldr r2, =interrupt_vectors_ram
    str r0, [r2, #VTOR_IRQ1_OFFSET]

    ldr r0, =PPB_VTOR
    ldr r1, =interrupt_vectors_ram
    str r1, [r0, #0]
    dsb                                 /* Barrera de sincronización de datos */
    isb                                 /* Barrera de instrucciones */

    /* 5. Limpiar pendientes y habilitar IRQ1 en el controlador NVIC */
    movs r1, #2                         /* Bit 1 = IRQ 1 */
    ldr r0, =NVIC_ICPR
    str r1, [r0, #0]
    ldr r0, =NVIC_ISER
    str r1, [r0, #0]

    pop {r4, pc}

/* ----------------------------------------------------------------------------
 * Subrutina: timer_start
 * Activa el temporizador de físicas y programa el primer disparo de ALARM1.
 * Parámetros: Ninguno | Retorno: Ninguno
 * ---------------------------------------------------------------------------- */
.thumb_func
timer_start:
    push {r4, lr}

    ldr r0, =physics_timer_enabled
    movs r1, #1
    str r1, [r0, #0]

    ldr r0, =frame_tick_pending
    movs r1, #0
    str r1, [r0, #0]

    ldr r0, =TIMER_BASE
    movs r1, #2                         /* Bit 1 = ALARM1 */
    str r1, [r0, #TIMER_INTR]           /* Limpiar flag residual */

    /* Habilitar bit 1 en TIMER_INTE */
    ldr r2, [r0, #TIMER_INTE]
    orrs r2, r1
    str r2, [r0, #TIMER_INTE]

    /* Programar ALARM1 = TIMERAWL + 33333 us */
    ldr r2, [r0, #TIMER_TIMERAWL]
    ldr r3, =FRAME_PERIOD_US
    adds r2, r2, r3
    str r2, [r0, #TIMER_ALARM1]

    pop {r4, pc}

/* ----------------------------------------------------------------------------
 * Subrutina: timer_stop
 * Detiene por completo el temporizador de físicas (usado en Game Over).
 * Parámetros: Ninguno | Retorno: Ninguno
 * ---------------------------------------------------------------------------- */
.thumb_func
timer_stop:
    push {r4, lr}

    /* Marcar temporizador como inactivo */
    ldr r0, =physics_timer_enabled
    movs r1, #0
    str r1, [r0, #0]

    /* Deshabilitar interrupción de ALARM1 en TIMER_INTE y desarmar hardware */
    ldr r0, =TIMER_BASE
    movs r1, #2                         /* Bit 1 = ALARM1 */
    ldr r2, [r0, #TIMER_INTE]
    bics r2, r1
    str r2, [r0, #TIMER_INTE]
    str r1, [r0, #TIMER_ARMED]          /* Desarma ALARM1 inmediatamente */
    str r1, [r0, #TIMER_INTR]           /* Limpia interrupción pendiente */

    pop {r4, pc}

/* ----------------------------------------------------------------------------
 * Subrutina: timer_check_and_clear_tick
 * Consulta si ocurrió el tick del temporizador de hardware y lo limpia.
 * Retorno: r0 = 1 si hay un nuevo frame listo, r0 = 0 si aún no toca.
 * ---------------------------------------------------------------------------- */
.thumb_func
timer_check_and_clear_tick:
    ldr r1, =frame_tick_pending
    ldr r0, [r1, #0]
    cmp r0, #0
    beq 1f
    movs r2, #0
    str r2, [r1, #0]                    /* Consumir el tick */
1:
    bx lr

/* ----------------------------------------------------------------------------
 * ISR: timer1_isr
 * Rutina de interrupción de hardware ejecutada automáticamente cada 33,333 us.
 * ---------------------------------------------------------------------------- */
.thumb_func
timer1_isr:
    push {r4, lr}

    /* 1. Reconocer y limpiar la interrupción en TIMER_INTR (escribir 1 en bit 1) */
    ldr r0, =TIMER_BASE
    movs r1, #2
    str r1, [r0, #TIMER_INTR]

    /* 2. Verificar si el temporizador de físicas sigue activo */
    ldr r2, =physics_timer_enabled
    ldr r3, [r2, #0]
    cmp r3, #0
    beq isr_exit

    /* 3. Reprogramar ALARM1 para el próximo frame (+33,333 us) */
    ldr r2, [r0, #TIMER_TIMERAWL]
    ldr r3, =FRAME_PERIOD_US
    adds r2, r2, r3
    str r2, [r0, #TIMER_ALARM1]

    /* 4. Activar bandera de sincronización de frame */
    ldr r0, =frame_tick_pending
    movs r1, #1
    str r1, [r0, #0]

isr_exit:
    pop {r4, pc}

.ltorg