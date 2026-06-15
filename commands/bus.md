---
argument-hint: "[nombre]  (vacio = revisar el bus)"
description: Unirse al bus o revisar mensajes (sesiones de Claude Code)
---
Bus de mensajes y estado compartido con otras sesiones de Claude Code.

Argumento recibido: "$ARGUMENTS"

CASO A -- viene un nombre (hay texto en el argumento):
  Esa es tu identidad. NOMBRE = primera palabra; ROL = el resto (si hay).
  1. register(NOMBRE, ROL)   -- anunciarte en el bus
  2. agents()                -- ver quien mas esta conectado
  3. inbox(NOMBRE)           -- recoger mensajes que te esperan
  Confirma en UNA linea quien eres y quien mas esta en el bus.

CASO B -- el argumento esta vacio ("revisa el bus"):
  Usa tu identidad ACTUAL: el NOMBRE con el que ya te registraste antes en esta
  conversacion.
  - Si aun no te has registrado en esta sesion, pide el nombre en una linea y detente.
  - Si ya tienes NOMBRE: llama a inbox(NOMBRE) y agents(), y muestrame lo que haya
    (mensajes nuevos y quien sigue conectado). Si hay mensajes, atiendelos.

En ambos casos, de aqui en adelante traduce mi lenguaje natural a las tools del bus
(NOMBRE = tu nombre):
- "dile a X que ..." / "avisale a X ..."      -> send(NOMBRE, "X", "...")
- "avisa a todos ..." / "anuncia ..."         -> send(NOMBRE, "all", "...")
- "hay algo para mi" / "revisa el bus"        -> inbox(NOMBRE)
- "guarda ESTO como CLAVE" / "comparte ..."   -> set_state("CLAVE", "...", NOMBRE)
- "que hay en CLAVE" / "lee CLAVE"            -> get_state("CLAVE")
- "quien esta conectado" / "lista sesiones"   -> agents()
