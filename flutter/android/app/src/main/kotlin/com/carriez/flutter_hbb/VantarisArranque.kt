package com.carriez.flutter_hbb

// Vantaris: arranque del servicio pedido por Vantaris Inicio (el launcher), sin que nadie abra la app.
//
// Landi instala Vantaris Soporte sola y nadie la abre nunca: sin abrirla, el servicio no arranca, el
// ID no llega al servidor y el alta automática (vantaris/alta.dart) no puede hacerse. Desde
// segundo plano Android 12+ no deja arrancar el servicio en primer plano, pero sí desde una
// actividad visible: el launcher abre esta (transparente, sin historial), que hace lo mismo que el
// arranque del equipo (BootReceiver) y se cierra en el acto.
//
//   am start -a es.vantaris.soporte.ARRANCAR   (o el Intent equivalente desde el launcher)

import android.app.Activity
import android.content.Intent
import android.os.Bundle

class VantarisArranque : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        try {
            BootReceiver().onReceive(this, Intent(VANTARIS_ARRANCAR))
        } finally {
            finish()
            overridePendingTransition(0, 0)
        }
    }
}
