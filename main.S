/* ============================================================================
 * Archivo: main.s
 * Descripción: Máquina de Estados Principal, Físicas 2D, Colisiones AABB,
 *              Interfaz HUD y Gestión de Reinicio para "ASTRO STRIKE".
 * Estándar: AAPCS (Preservación de r4-r7, lr y pila alineada a 8 bytes)
 * ============================================================================ */

.syntax unified
.cpu cortex-m0plus
.thumb

/* --- Estados de la Máquina de Estados Finita (FSM) --- */
.equ STATE_MENU,        0
.equ STATE_PLAYING,     1
.equ STATE_GAMEOVER,    2

/* --- Variables de Estado del Videojuego en RAM --- */
.section .bss
.align 2
current_game_state:     .space 4                /* Estado actual (0=Menú, 1=Juego, 2=GameOver) */
player_score:          .space 4                /* Puntuación del jugador (0..999) */
remaining_lives:          .space 4                /* Vidas restantes (0..3) */
player_position_x:       .space 4                /* Coordenada X de la nave (4..100) */
player_position_y:       .space 4                /* Coordenada Y de la nave (12..55) */
laser_position_x:        .space 4                /* Coordenada X del proyectil láser */
laser_position_y:        .space 4                /* Coordenada Y del proyectil láser */
laser_in_flight:   .space 4                /* 1 = Láser en vuelo, 0 = Listo para disparar */
enemy_positions_x:        .space 12               /* Arreglo de 3 palabras: X de los 3 enemigos */
enemy_positions_y:        .space 12               /* Arreglo de 3 palabras: Y de los 3 enemigos */
enemy_height_lfsr_state:      .space 4                /* Semilla pseudoaleatoria para alturas de enemigos */

/* --- Código Principal --- */
.section .text
.align 2

.global game_main

/* ----------------------------------------------------------------------------
 * Punto de entrada principal desde el archivo .ino
 * ---------------------------------------------------------------------------- */
.thumb_func
game_main:
    push {r4, lr}

    /* 1. Inicializar periféricos Bare-Metal (Inputs, Video I2C y Timer NVIC) */
    bl inputs_init
    bl video_init
    bl timer_init

    /* 2. Inicializar semilla LFSR y estado inicial en Menú Principal */
    ldr r0, =enemy_height_lfsr_state
    ldr r1, =0xACE1
    str r1, [r0, #0]

    ldr r0, =current_game_state
    movs r1, #STATE_MENU
    str r1, [r0, #0]

    /* Dibujar pantalla estática inicial del Menú Principal */
    bl render_menu_screen

/* --- Bucle Principal de la Máquina de Estados --- */
main_loop:
    ldr r0, =current_game_state
    ldr r1, [r0, #0]

    cmp r1, #STATE_MENU
    beq handle_state_menu

    cmp r1, #STATE_PLAYING
    beq handle_state_playing

    b handle_state_gameover

/* ----------------------------------------------------------------------------
 * Estado 0: MENÚ PRINCIPAL
 * Pantalla inicial estática que arranca al pulsar el botón Z del joystick.
 * ---------------------------------------------------------------------------- */
handle_state_menu:
    bl read_btn_z_pressed
    cmp r0, #1
    bne main_loop

    /* Al pulsar Z: inicializar registros de estado, arrancar Timer e ir a PLAYING */
    bl reset_game_state
    bl timer_start

    ldr r0, =current_game_state
    movs r1, #STATE_PLAYING
    str r1, [r0, #0]
    b main_loop

/* ----------------------------------------------------------------------------
 * Estado 1: JUEGO EN CURSO (Sincronizado por Interrupción de Hardware a 30 FPS)
 * ---------------------------------------------------------------------------- */
handle_state_playing:
    /* Esperar a que la interrupción de hardware (ALARM1) active frame_tick_pending */
    bl timer_check_and_clear_tick
    cmp r0, #0
    beq main_loop                       /* Sin delay loops: espera limpia al evento de IRQ */

    /* Actualizar físicas, colisiones y renderizar el Framebuffer a 30 FPS */
    bl update_game_physics
    bl render_game_frame
    b main_loop

/* ----------------------------------------------------------------------------
 * Estado 2: GAME OVER
 * Temporizador de físicas detenido; espera el botón Z para reiniciar.
 * ---------------------------------------------------------------------------- */
handle_state_gameover:
    bl read_btn_z_pressed
    cmp r0, #1
    bne main_loop

    /* Al pulsar Z: reiniciar registros de estado, reactivar Timer y jugar */
    bl reset_game_state
    bl timer_start

    ldr r0, =current_game_state
    movs r1, #STATE_PLAYING
    str r1, [r0, #0]
    b main_loop

.ltorg

/* ----------------------------------------------------------------------------
 * Subrutina: reset_game_state
 * Reinicia todos los registros y variables de estado del juego en RAM.
 * ---------------------------------------------------------------------------- */
.thumb_func
reset_game_state:
    push {r4, lr}

    ldr r0, =player_score
    movs r1, #0
    str r1, [r0, #0]

    ldr r0, =remaining_lives
    movs r1, #3
    str r1, [r0, #0]

    ldr r0, =player_position_x
    movs r1, #10
    str r1, [r0, #0]

    ldr r0, =player_position_y
    movs r1, #32
    str r1, [r0, #0]

    ldr r0, =laser_in_flight
    movs r1, #0
    str r1, [r0, #0]

    /* Posiciones iniciales escalonadas para los 3 enemigos */
    ldr r0, =enemy_positions_x
    movs r1, #120
    str r1, [r0, #0]
    movs r1, #155
    str r1, [r0, #4]
    movs r1, #190
    str r1, [r0, #8]

    ldr r0, =enemy_positions_y
    movs r1, #16
    str r1, [r0, #0]
    movs r1, #34
    str r1, [r0, #4]
    movs r1, #50
    str r1, [r0, #8]

    pop {r4, pc}

/* ----------------------------------------------------------------------------
 * Subrutina: next_random_y
 * Calcula mediante un LFSR de 16 bits una coordenada Y válida para enemigos (12..54).
 * Retorno: r0 = coordenada Y pseudoaleatoria
 * ---------------------------------------------------------------------------- */
.thumb_func
next_random_y:
    ldr r1, =enemy_height_lfsr_state
    ldr r0, [r1, #0]
    lsrs r2, r0, #1
    movs r3, #1
    ands r0, r3
    beq 1f
    ldr r3, =0xB400
    eors r2, r3
1:
    str r2, [r1, #0]
    movs r0, #0x1F                      /* 0..31 */
    ands r0, r2
    adds r0, r0, #14                    /* Rango Y = 14..45 (bajo la línea del HUD) */
    bx lr

/* ----------------------------------------------------------------------------
 * Subrutina: update_game_physics
 * Ejecuta una iteración de físicas: movimiento X/Y, proyectiles, enemigos y colisiones.
 * ---------------------------------------------------------------------------- */
.thumb_func
update_game_physics:
    push {r3, r4, r5, r6, r7, lr}

    /* 1. Leer eje X del ADC y mover jugador dentro de límites (2..96) */
    bl read_adc_x
    ldr r1, =player_position_x
    ldr r2, [r1, #0]
    adds r2, r2, r0
    cmp r2, #2
    bge 1f
    movs r2, #2
1:
    cmp r2, #96
    ble 2f
    movs r2, #96
2:
    str r2, [r1, #0]

    /* 2. Leer eje Y del ADC y mover jugador dentro de límites (12..55) */
    bl read_adc_y
    ldr r1, =player_position_y
    ldr r2, [r1, #0]
    adds r2, r2, r0
    cmp r2, #12
    bge 3f
    movs r2, #12
3:
    cmp r2, #55
    ble 4f
    movs r2, #55
4:
    str r2, [r1, #0]

    /* 3. Actualizar proyectil láser (disparo continuo automático o por botón Z) */
    ldr r4, =laser_in_flight
    ldr r0, [r4, #0]
    cmp r0, #0
    bne laser_move

    /* Disparar nuevo proyectil desde el cañón frontal de la nave */
    movs r0, #1
    str r0, [r4, #0]
    ldr r0, =player_position_x
    ldr r0, [r0, #0]
    adds r0, r0, #8
    ldr r1, =laser_position_x
    str r0, [r1, #0]

    ldr r0, =player_position_y
    ldr r0, [r0, #0]
    adds r0, r0, #3
    ldr r1, =laser_position_y
    str r0, [r1, #0]
    b enemies_update

laser_move:
    ldr r1, =laser_position_x
    ldr r0, [r1, #0]
    adds r0, r0, #5                     /* Velocidad del láser: 5 px/frame */
    cmp r0, #126
    blt 5f
    movs r0, #0
    str r0, [r4, #0]                    /* Desactivar al salir por la derecha */
    b enemies_update
5:
    str r0, [r1, #0]

    /* 4. Actualizar los 3 enemigos y verificar colisiones */
enemies_update:
    movs r7, #0                         /* Índice de enemigo i = 0..2 */

enemy_loop:
    lsls r6, r7, #2                     /* Offset en bytes = i * 4 */
    ldr r4, =enemy_positions_x
    ldr r5, =enemy_positions_y

    ldr r0, [r4, r6]                    /* r0 = enemy_positions_x[i] */
    subs r0, r0, #2                     /* Velocidad enemiga: 2 px/frame a la izquierda */
    str r0, [r4, r6]

    /* ¿El enemigo rebasó el borde izquierdo (X <= 0)? -> Pierde 1 vida */
    cmp r0, #0
    bgt check_laser_hit

    bl lose_one_life
    bl next_random_y
    str r0, [r5, r6]
    movs r0, #128
    str r0, [r4, r6]
    b next_enemy

check_laser_hit:
    /* Verificar colisión Láser vs Enemigo[i] */
    ldr r1, =laser_in_flight
    ldr r1, [r1, #0]
    cmp r1, #0
    beq check_player_hit

    ldr r1, =laser_position_x
    ldr r1, [r1, #0]                    /* r1 = laser_position_x */
    ldr r2, [r4, r6]                    /* r2 = enemy_positions_x[i] */

    /* Condición X: laser_position_x + 4 >= enemy_positions_x && laser_position_x <= enemy_positions_x + 8 */
    adds r3, r1, #4
    cmp r3, r2
    blt check_player_hit
    adds r3, r2, #4
    adds r3, r3, #4
    cmp r1, r3
    bgt check_player_hit

    /* Condición Y: laser_position_y + 2 >= enemy_positions_y && laser_position_y <= enemy_positions_y + 8 */
    ldr r1, =laser_position_y
    ldr r1, [r1, #0]                    /* r1 = laser_position_y */
    ldr r2, [r5, r6]                    /* r2 = enemy_positions_y[i] */
    adds r3, r1, #2
    cmp r3, r2
    blt check_player_hit
    adds r3, r2, #4
    adds r3, r3, #4
    cmp r1, r3
    bgt check_player_hit

    /* ¡Impacto de láser confirmado! Desactivar láser, sumar 10 puntos y reaparecer enemigo */
    ldr r0, =laser_in_flight
    movs r1, #0
    str r1, [r0, #0]

    ldr r0, =player_score
    ldr r1, [r0, #0]
    adds r1, r1, #10
    ldr r2, =999
    cmp r1, r2
    ble 6f
    movs r1, r2
6:
    str r1, [r0, #0]

    bl next_random_y
    str r0, [r5, r6]
    movs r0, #128
    str r0, [r4, r6]
    b next_enemy

check_player_hit:
    /* Verificar colisión AABB Jugador (8x8) vs Enemigo[i] (8x8) */
    ldr r0, =player_position_x
    ldr r0, [r0, #0]                    /* player_position_x */
    ldr r1, [r4, r6]                    /* enemy_positions_x[i] */

    adds r2, r0, #7
    cmp r2, r1
    blt next_enemy
    adds r2, r1, #7
    cmp r0, r2
    bgt next_enemy

    ldr r0, =player_position_y
    ldr r0, [r0, #0]                    /* player_position_y */
    ldr r1, [r5, r6]                    /* enemy_positions_y[i] */

    adds r2, r0, #7
    cmp r2, r1
    blt next_enemy
    adds r2, r1, #7
    cmp r0, r2
    bgt next_enemy

    /* ¡Colisión con el jugador! Restar vida y reposicionar enemigo */
    bl lose_one_life
    bl next_random_y
    str r0, [r5, r6]
    movs r0, #128
    str r0, [r4, r6]

next_enemy:
    adds r7, r7, #1
    cmp r7, #3
    blt enemy_loop

    /* 5. Verificar condición de fin de partida (remaining_lives == 0) */
    ldr r0, =remaining_lives
    ldr r0, [r0, #0]
    cmp r0, #0
    bgt physics_done

    /* Detener por completo el temporizador de físicas y cambiar a STATE_GAMEOVER */
    bl timer_stop
    ldr r0, =current_game_state
    movs r1, #STATE_GAMEOVER
    str r1, [r0, #0]
    bl render_gameover_screen

physics_done:
    pop {r3, r4, r5, r6, r7, pc}

.ltorg

/* ----------------------------------------------------------------------------
 * Subrutina auxiliar: lose_one_life
 * Decrementa en 1 el contador de vidas si es mayor a 0.
 * ---------------------------------------------------------------------------- */
.thumb_func
lose_one_life:
    ldr r0, =remaining_lives
    ldr r1, [r0, #0]
    cmp r1, #0
    ble 1f
    subs r1, r1, #1
    str r1, [r0, #0]
1:
    bx lr

.ltorg

/* ----------------------------------------------------------------------------
 * Subrutina: render_menu_screen
 * Renderiza la pantalla inicial estática con el nombre del juego.
 * ---------------------------------------------------------------------------- */
.thumb_func
render_menu_screen:
    push {r4, lr}
    bl fb_clear

    movs r0, #4
    bl fb_draw_hline

    movs r0, #16
    movs r1, #14
    ldr r2, =str_title
    bl fb_draw_string

    /* Dibujar nave decorativa en el centro */
    movs r0, #60
    movs r1, #28
    ldr r2, =sprite_player
    bl fb_draw_sprite

    movs r0, #8
    movs r1, #44
    ldr r2, =str_press_z
    bl fb_draw_string

    movs r0, #58
    bl fb_draw_hline

    bl oled_flush
    pop {r4, pc}

.ltorg

.ltorg

/* ----------------------------------------------------------------------------
 * Subrutina: render_game_frame
 * Renderiza el HUD superior, la nave, el láser y los enemigos en el Framebuffer.
 * ---------------------------------------------------------------------------- */
.thumb_func
render_game_frame:
    push {r4, r5, r6, lr}

    /* Si acaba de pasar a GAMEOVER en este frame, no sobreescribir pantalla final */
    ldr r0, =current_game_state
    ldr r0, [r0, #0]
    cmp r0, #STATE_PLAYING
    bne render_frame_exit

    bl fb_clear

    /* 1. Dibujar Interfaz HUD: "PTS:xxx   VID:x" */
    movs r0, #0
    movs r1, #0
    ldr r2, =str_hud_pts
    bl fb_draw_string

    movs r0, #32
    movs r1, #0
    ldr r2, =player_score
    ldr r2, [r2, #0]
    bl fb_draw_num3

    movs r0, #80
    movs r1, #0
    ldr r2, =str_hud_vid
    bl fb_draw_string

    ldr r2, =remaining_lives
    ldr r2, [r2, #0]
    adds r2, r2, #'0'
    movs r0, #112
    movs r1, #0
    bl fb_draw_char

    /* Línea divisoria del HUD en Y = 9 */
    movs r0, #9
    bl fb_draw_hline

    /* 2. Dibujar nave del jugador */
    ldr r0, =player_position_x
    ldr r0, [r0, #0]
    ldr r1, =player_position_y
    ldr r1, [r1, #0]
    ldr r2, =sprite_player
    bl fb_draw_sprite

    /* 3. Dibujar proyectil láser (4 píxeles horizontales) si está activo */
    ldr r0, =laser_in_flight
    ldr r0, [r0, #0]
    cmp r0, #0
    beq draw_enemies

    ldr r4, =laser_position_x
    ldr r4, [r4, #0]
    ldr r5, =laser_position_y
    ldr r5, [r5, #0]
    movs r6, #0
laser_draw_loop:
    adds r0, r4, r6
    movs r1, r5
    bl fb_draw_pixel
    adds r6, r6, #1
    cmp r6, #4
    blt laser_draw_loop

    /* 4. Dibujar los 3 enemigos */
draw_enemies:
    movs r4, #0                         /* i = 0..2 */
enemy_draw_loop:
    lsls r5, r4, #2
    ldr r0, =enemy_positions_x
    ldr r0, [r0, r5]
    ldr r1, =enemy_positions_y
    ldr r1, [r1, r5]
    ldr r2, =sprite_enemy
    bl fb_draw_sprite

    adds r4, r4, #1
    cmp r4, #3
    blt enemy_draw_loop

    /* 5. Volcar Framebuffer completo a la pantalla OLED */
    bl oled_flush

render_frame_exit:
    pop {r4, r5, r6, pc}

.ltorg

/* ----------------------------------------------------------------------------
 * Subrutina: render_gameover_screen
 * Muestra la pantalla de Game Over con el puntaje final alcanzado.
 * ---------------------------------------------------------------------------- */
.thumb_func
render_gameover_screen:
    push {r4, lr}
    bl fb_clear

    movs r0, #4
    bl fb_draw_hline

    movs r0, #28
    movs r1, #12
    ldr r2, =str_gameover
    bl fb_draw_string

    movs r0, #28
    movs r1, #28
    ldr r2, =str_hud_pts
    bl fb_draw_string

    movs r0, #60
    movs r1, #28
    ldr r2, =player_score
    ldr r2, [r2, #0]
    bl fb_draw_num3

    movs r0, #8
    movs r1, #46
    ldr r2, =str_press_z
    bl fb_draw_string

    movs r0, #58
    bl fb_draw_hline

    bl oled_flush
    pop {r4, pc}

.ltorg

/* --- Datos Constantes: Sprites 8x8 y Textos --- */
.section .rodata
.align 2

/* Sprite 8x8: Nave Espacial del Jugador (apuntando a la derecha) */
sprite_player:
    .byte 0b11000000
    .byte 0b11110000
    .byte 0b01111100
    .byte 0b11111111
    .byte 0b11111111
    .byte 0b01111100
    .byte 0b11110000
    .byte 0b11000000

/* Sprite 8x8: Invasor / Asteroide Enemigo */
sprite_enemy:
    .byte 0b00111100
    .byte 0b01111110
    .byte 0b11011011
    .byte 0b11111111
    .byte 0b11111111
    .byte 0b01011010
    .byte 0b10000001
    .byte 0b01000010

str_title:
    .asciz "ASTRO STRIKE"
str_press_z:
    .asciz "PULSA Z INICIAR"
str_hud_pts:
    .asciz "PTS:"
str_hud_vid:
    .asciz "VID:"
str_gameover:
    .asciz "GAME OVER"