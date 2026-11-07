// Archivo mínimo de arranque para ceder el control a Ensamblador ARM (.S).

extern "C" {
  void game_main(void);
}

void setup() {
  game_main();
}

void loop() {
}
