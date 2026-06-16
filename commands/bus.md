---
argument-hint: "[nombre]  (vacio = revisar el bus)"
description: Unirse al bus o revisar mensajes (sesiones de Claude Code)
---
Bus de mensajes y estado compartido con otras sesiones de Claude Code.

Argumento recibido: "$ARGUMENTS"

CASO A -- viene un nombre (hay texto en el argumento):
  Esa es tu identidad. NOMBRE = primera palabra; ROL = el resto (si hay).
  1. register(NOMBRE, ROL)   -- anunciarte y fijar tu identidad en el bus
  2. agents()                -- ver quien mas esta conectado (y solapamientos)
  3. inbox()                 -- recoger mensajes que te esperan
  Confirma en UNA linea quien eres y quien mas esta en el bus.

CASO B -- el argumento esta vacio ("revisa el bus"):
  Usa tu identidad ACTUAL: el NOMBRE con el que ya te registraste antes en esta
  conversacion.
  - Si aun no te has registrado en esta sesion, pide el nombre en una linea y detente.
  - Si ya tienes NOMBRE: llama a inbox() y agents(), y muestrame lo que haya
    (mensajes nuevos y quien sigue conectado). Si hay mensajes, atiendelos.

Ritual recomendado antes de tocar trabajo compartido: register -> agents ->
get_state -> inbox (anunciate, mira quien mas esta y si se solapan, lee el estado
compartido, y vacia tu bandeja).

Tu identidad queda ligada a la sesion con register: los tools de stdio (send,
inbox, claim, release, whoami) usan tu identidad fijada, asi que ya NO se pasa
"NOMBRE" como argumento ni se puede suplantar a otra sesion.

En ambos casos, de aqui en adelante traduce mi lenguaje natural a las tools del bus:
- "quien soy" / "como me llamo"               -> whoami()
- "dile a X que ..." / "avisale a X ..."      -> send("X", "...")
- "avisa a todos ..." / "anuncia ..."         -> send("all", "...")
- "responde al mensaje N ..."                 -> send("X", "...", reply_to=N)
- "hay algo para mi" / "revisa el bus"        -> inbox()
- "echa un vistazo sin marcar leido"          -> inbox(peek=True)
- "quien leyo el mensaje N"                    -> message_status(N)
- "guarda ESTO como CLAVE"                    -> set_state("CLAVE", "...")
- "guarda solo si sigue en version V"         -> set_state("CLAVE", "...", expected_version=V)
- "agrega ESTO a CLAVE"                       -> set_state("CLAVE", "...", mode="append")
- "que hay en CLAVE" / "lee CLAVE"            -> get_state("CLAVE")
- "que claves hay" / "lista el estado"        -> list_state()
- "estoy editando ARCHIVO"                    -> claim("ARCHIVO")
- "ya termine con ARCHIVO"                     -> release("ARCHIVO")
- "quien edita que" / "lista reclamos"        -> list_claims()
- "quien esta conectado" / "lista sesiones"   -> agents()
