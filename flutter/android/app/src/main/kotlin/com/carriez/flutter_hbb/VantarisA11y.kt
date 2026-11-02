package com.carriez.flutter_hbb

// Vantaris: la accesibilidad (el «Control de entrada», lo que deja tocar la pantalla al técnico) se
// pierde sola cuando Android detiene la app a la fuerza: «Forzar detención» en Ajustes, la limpieza
// de apps «en suspensión» de Samsung (Mantenimiento del dispositivo) o un force-stop por adb. Es una
// medida de seguridad de Android: al parar la app la quita de la lista de servicios activos.
//
// Arreglo: scripts/provisionar-android.ps1 concede WRITE_SECURE_SETTINGS por adb (solo se puede dar
// así, nunca desde la propia app) y con eso la app vuelve a añadirse a la lista cada vez que arranca
// el servicio o el equipo. Sin ese permiso no hace nada (y la tarjeta de permisos lo enseña apagado).

import android.content.ComponentName
import android.content.Context
import android.content.pm.PackageManager
import android.provider.Settings
import android.util.Log

object VantarisA11y {
    private const val TAG = "VantarisA11y"

    fun ensureEnabled(ctx: Context) {
        try {
            if (ctx.checkSelfPermission(android.Manifest.permission.WRITE_SECURE_SETTINGS) !=
                PackageManager.PERMISSION_GRANTED
            ) return
            val mine = ComponentName(ctx.packageName, InputService::class.java.name).flattenToString()
            val cr = ctx.contentResolver
            val actual = Settings.Secure.getString(cr, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES) ?: ""
            val lista = actual.split(':').filter { it.isNotBlank() }
            if (lista.any { ComponentName.unflattenFromString(it)?.flattenToString() == mine }) return
            Settings.Secure.putString(
                cr, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES, (lista + mine).joinToString(":")
            )
            Settings.Secure.putInt(cr, Settings.Secure.ACCESSIBILITY_ENABLED, 1)
            Log.i(TAG, "accesibilidad recuperada")
        } catch (e: Exception) {
            Log.w(TAG, "no se pudo recuperar la accesibilidad: $e")
        }
    }
}
