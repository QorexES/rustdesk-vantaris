// Vantaris Cobertura: tarjeta de la pantalla principal de Vantaris Soporte que abre la herramienta.
// Android: página nueva. Windows: pestaña de la ventana principal (como Ajustes), que se agranda.

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../common.dart';
import '../../desktop/widgets/tabbar_widget.dart';
import '../tecnico.dart';
import 'pagina.dart';

const kTabCobertura = 'Cobertura';

void abrirCobertura(BuildContext context) {
  if (isDesktop) {
    try {
      Get.find<DesktopTabController>().add(TabInfo(
        key: kTabCobertura,
        label: kTabCobertura,
        selectedIcon: Icons.wifi_tethering,
        unselectedIcon: Icons.wifi_tethering_outlined,
        page: const CoberturaPagina(key: ValueKey(kTabCobertura)),
      ));
    } catch (e) {
      debugPrintStack(label: '$e');
    }
    return;
  }
  Navigator.of(context).push(MaterialPageRoute(builder: (_) => const CoberturaPagina(conBarra: true)));
}

class VantarisCoberturaCard extends StatelessWidget {
  const VantarisCoberturaCard({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    // Solo en Soporte (el equipo que está en el local); el Técnico no la enseña.
    if (vantarisEsTecnico) return const SizedBox.shrink();
    final t = Theme.of(context);
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      constraints: const BoxConstraints(maxWidth: 520),
      child: Material(
        color: kCoberturaTeal.withOpacity(0.10),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: kCoberturaTeal.withOpacity(0.6)),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => abrirCobertura(context),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
            child: Row(children: [
              const Icon(Icons.wifi_tethering, color: kCoberturaTeal, size: 26),
              const SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('Cobertura del local', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                  Text('Mapa de la WiFi y del 4G para saber dónde poner el TPV',
                      style: TextStyle(fontSize: 11.5, color: t.hintColor)),
                ]),
              ),
              Icon(Icons.chevron_right, color: t.hintColor),
            ]),
          ),
        ),
      ),
    );
  }
}
