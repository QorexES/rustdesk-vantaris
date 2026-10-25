// Vantaris: capa del técnico para dibujar o señalar sobre la vista remota (escritorio).
// Con la pizarra activa, el ratón dibuja, pone formas o señala en vez de controlar el equipo
// remoto; al cerrarla todo vuelve a funcionar como siempre.
// Todo se envía con VantarisDrawSender y se ve en local con su VantarisScene.
//
// Ojo: solo tiene sentido contra clientes Vantaris. Un RustDesk oficial recibiría los trazos
// como mensajes de chat ilegibles (por eso se pregunta antes, ver vantarisPeerSupportsDraw).

import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../common.dart';
import '../models/model.dart';
import 'capture.dart';
import 'draw.dart';
import 'scene.dart';

/// Herramientas de la pizarra, en el orden de la barra.
enum VantarisTool { pen, laser, arrow, rect, ellipse, triangle, line, number, text, focus }

const _toolInfo = <VantarisTool, (IconData, String)>{
  VantarisTool.pen: (Icons.edit, 'Lápiz: dibujar a mano alzada (P)'),
  VantarisTool.laser: (Icons.adjust, 'Láser: señalar sin dibujar (L)'),
  VantarisTool.arrow: (Icons.north_east, 'Flecha (F)'),
  VantarisTool.rect: (Icons.crop_square, 'Rectángulo (R)'),
  VantarisTool.ellipse: (Icons.circle_outlined, 'Círculo (C)'),
  VantarisTool.triangle: (Icons.change_history, 'Triángulo (T)'),
  VantarisTool.line: (Icons.horizontal_rule, 'Línea (I)'),
  VantarisTool.number: (Icons.looks_one_outlined, 'Números de paso: 1, 2, 3… (N)'),
  VantarisTool.text: (Icons.text_fields, 'Texto (X)'),
  VantarisTool.focus: (Icons.center_focus_strong, 'Foco: oscurecer todo menos una zona (O)'),
};

const _shapeOf = <VantarisTool, VantarisShape>{
  VantarisTool.arrow: VantarisShape.arrow,
  VantarisTool.rect: VantarisShape.rect,
  VantarisTool.ellipse: VantarisShape.ellipse,
  VantarisTool.triangle: VantarisShape.triangle,
  VantarisTool.line: VantarisShape.line,
};

final _shortcuts = <LogicalKeyboardKey, VantarisTool>{
  LogicalKeyboardKey.keyP: VantarisTool.pen,
  LogicalKeyboardKey.keyL: VantarisTool.laser,
  LogicalKeyboardKey.keyF: VantarisTool.arrow,
  LogicalKeyboardKey.keyR: VantarisTool.rect,
  LogicalKeyboardKey.keyC: VantarisTool.ellipse,
  LogicalKeyboardKey.keyT: VantarisTool.triangle,
  LogicalKeyboardKey.keyI: VantarisTool.line,
  LogicalKeyboardKey.keyN: VantarisTool.number,
  LogicalKeyboardKey.keyX: VantarisTool.text,
  LogicalKeyboardKey.keyO: VantarisTool.focus,
};

class VantarisDrawState {
  static final _states = <SessionID, VantarisDrawState>{};

  static VantarisDrawState of(FFI ffi) =>
      _states.putIfAbsent(ffi.sessionId, () => VantarisDrawState._(ffi.sessionId));

  static void disposeFor(SessionID sessionId) {
    _states.remove(sessionId)?.sender.dispose();
    vantarisForgetSession(sessionId);
  }

  VantarisDrawState._(this.sessionId) : sender = VantarisDrawSender(sessionId);

  final SessionID sessionId;
  final VantarisDrawSender sender;
  final RxBool active = false.obs;
  final RxBool checking = false.obs;
  final Rx<Color> color = kVantarisDrawColors.first.obs;
  final RxInt width = kVantarisDrawWidths[1].obs;
  final Rx<VantarisTool> tool = VantarisTool.pen.obs;
  final RxBool pinned = false.obs;
  final RxBool focusOn = false.obs;

  bool get laser => tool.value == VantarisTool.laser;

  void setTool(VantarisTool t) {
    if (tool.value == t) return;
    if (laser) sender.laserOff();
    tool.value = t;
  }

  void setPinned(bool on) {
    sender.setPinned(on);
    pinned.value = on;
  }

  void clear() {
    sender.clear();
    focusOn.value = false;
  }

  void focusOff() {
    sender.focusOff();
    focusOn.value = false;
  }

  Future<void> toggle() async {
    if (active.value) {
      sender.end();
      if (laser) sender.laserOff();
      active.value = false;
      return;
    }
    if (checking.value) return;
    checking.value = true;
    final ok = await vantarisPeerSupportsDraw(sessionId);
    checking.value = false;
    if (ok) {
      active.value = true;
    } else {
      showToast('Este equipo no tiene el cliente Vantaris: no se puede dibujar en él.',
          timeout: const Duration(seconds: 5));
    }
  }
}

/// Se añade encima de la imagen remota en la página remota de escritorio.
class VantarisDrawLayer extends StatelessWidget {
  final FFI ffi;
  const VantarisDrawLayer({Key? key, required this.ffi}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final state = VantarisDrawState.of(ffi);
    return Obx(() => state.active.isFalse
        ? const Offstage()
        : Positioned.fill(child: _DrawCanvas(ffi: ffi, state: state)));
  }
}

class _DrawCanvas extends StatefulWidget {
  final FFI ffi;
  final VantarisDrawState state;
  const _DrawCanvas({required this.ffi, required this.state});

  @override
  State<_DrawCanvas> createState() => _DrawCanvasState();
}

class _DrawCanvasState extends State<_DrawCanvas> {
  Timer? _ticker;
  Offset? _dragFrom; // normalizado, para formas y foco
  bool _drawing = false;
  final _focusNode = FocusNode(debugLabel: 'vantaris-draw');

  VantarisDrawSender get _sender => widget.state.sender;

  @override
  void initState() {
    super.initState();
    _sender.onChanged = _changed;
    // Mientras se dibuja, el teclado es de la pizarra (atajos) y no del equipo remoto.
    widget.ffi.inputModel.enterOrLeave(false);
    WidgetsBinding.instance.addPostFrameCallback((_) => _focusNode.requestFocus());
  }

  @override
  void dispose() {
    _ticker?.cancel();
    if (_sender.onChanged == _changed) _sender.onChanged = null;
    _focusNode.dispose();
    widget.ffi.inputModel.enterOrLeave(true);
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    setState(() {});
    _startTicker();
  }

  // Repinta mientras haya cosas caducando o el láser encendido, igual que en el equipo remoto.
  void _startTicker() {
    _ticker ??= Timer.periodic(const Duration(milliseconds: 40), (_) {
      if (!mounted) return;
      setState(() {});
      if (!_sender.scene.animating) {
        _ticker?.cancel();
        _ticker = null;
      }
    });
  }

  /// Zona de la vista local donde se ve la pantalla remota (misma cuenta que InputModel).
  Rect? _imageArea() {
    final c = widget.ffi.canvasModel;
    final rect = widget.ffi.ffiModel.rect;
    if (rect == null || rect.width <= 0 || rect.height <= 0 || c.scale <= 0) {
      return null;
    }
    final imageWidth = rect.width * c.scale;
    final imageHeight = rect.height * c.scale;
    double left, top;
    if (c.scrollStyle != ScrollStyle.scrollauto) {
      left = -imageWidth * c.scrollX;
      top = -imageHeight * c.scrollY;
      if (c.size.width > imageWidth) left += (c.size.width - imageWidth) / 2;
      if (c.size.height > imageHeight) top += (c.size.height - imageHeight) / 2;
    } else {
      left = c.x;
      top = c.y;
    }
    return Rect.fromLTWH(left, top, imageWidth, imageHeight);
  }

  /// Punto local de la vista -> 0..1 sobre la pantalla remota. [clamp]: pega al borde en vez de
  /// descartar (para arrastres que se salen).
  Offset? _normalize(Offset p, {bool clamp = false}) {
    final a = _imageArea();
    if (a == null) return null;
    final nx = (p.dx - a.left) / a.width;
    final ny = (p.dy - a.top) / a.height;
    if (clamp) return Offset(nx.clamp(0.0, 1.0), ny.clamp(0.0, 1.0));
    if (nx < 0 || ny < 0 || nx > 1 || ny > 1) return null;
    return Offset(nx, ny);
  }

  void _prepare() {
    _sender.displayRect = widget.ffi.ffiModel.rect;
    _sender.color = widget.state.color.value;
    _sender.widthPermille = widget.state.width.value;
  }

  // Láser: cada movimiento manda la posición; fuera de la pantalla remota se apaga.
  void _laserMove(Offset local) {
    _prepare();
    final n = _normalize(local);
    if (n == null) {
      _sender.laserOff();
      return;
    }
    _sender.laser(n.dx, n.dy);
  }

  void _down(PointerDownEvent e) {
    _focusNode.requestFocus();
    if (e.buttons != kPrimaryMouseButton) return;
    final tool = widget.state.tool.value;
    if (tool == VantarisTool.laser) return;
    _prepare();
    final n = _normalize(e.localPosition);
    if (n == null) return;
    switch (tool) {
      case VantarisTool.pen:
        _sender.start(n.dx, n.dy);
        _drawing = true;
        break;
      case VantarisTool.number:
        _sender.number(n);
        break;
      case VantarisTool.text:
        _askText(n);
        break;
      default: // formas y foco: se arrastra
        _dragFrom = n;
        break;
    }
  }

  void _move(PointerMoveEvent e) {
    final tool = widget.state.tool.value;
    if (tool == VantarisTool.laser) {
      _laserMove(e.localPosition);
      return;
    }
    if (_drawing) {
      final n = _normalize(e.localPosition);
      if (n != null) _sender.move(n.dx, n.dy);
      return;
    }
    final from = _dragFrom;
    if (from == null) return;
    final n = _normalize(e.localPosition, clamp: true);
    if (n == null) return;
    if (tool == VantarisTool.focus) {
      _sender.focus(from, n);
      widget.state.focusOn.value = true;
    } else if (_shapeOf[tool] != null) {
      _sender.shape(_shapeOf[tool]!, from, n);
    }
  }

  void _up() {
    _drawing = false;
    _dragFrom = null;
    _sender.end();
  }

  Future<void> _askText(Offset at) async {
    final ctrl = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Texto en la pantalla del cliente'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLength: 120,
          decoration: const InputDecoration(hintText: 'Ej.: Pulsa aquí'),
          onSubmitted: (v) => Navigator.of(ctx).pop(v),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(), child: const Text('Cancelar')),
          ElevatedButton(
              onPressed: () => Navigator.of(ctx).pop(ctrl.text),
              child: const Text('Poner')),
        ],
      ),
    );
    if (text != null && text.trim().isNotEmpty) {
      _prepare();
      _sender.text(at, text);
    }
    _focusNode.requestFocus();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    final ctrl = HardwareKeyboard.instance.isControlPressed;
    if (ctrl && e.logicalKey == LogicalKeyboardKey.keyZ) {
      _sender.undo();
      return KeyEventResult.handled;
    }
    if (ctrl) return KeyEventResult.ignored;
    if (e.logicalKey == LogicalKeyboardKey.escape) {
      widget.state.toggle();
      return KeyEventResult.handled;
    }
    if (e.logicalKey == LogicalKeyboardKey.keyG) {
      vantarisCaptureAnnotated(widget.ffi, _sender.scene);
      return KeyEventResult.handled;
    }
    if (e.logicalKey == LogicalKeyboardKey.delete) {
      widget.state.clear();
      return KeyEventResult.handled;
    }
    final t = _shortcuts[e.logicalKey];
    if (t != null) {
      widget.state.setTool(t);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _focusNode,
      onKeyEvent: _onKey,
      child: Stack(children: [
        Positioned.fill(
          child: Obx(() => MouseRegion(
                cursor: widget.state.laser
                    ? SystemMouseCursors.none
                    : widget.state.tool.value == VantarisTool.text
                        ? SystemMouseCursors.text
                        : SystemMouseCursors.precise,
                onExit: (_) {
                  if (widget.state.laser) _sender.laserOff();
                },
                child: Listener(
                  behavior: HitTestBehavior.opaque,
                  onPointerDown: _down,
                  onPointerMove: _move,
                  onPointerHover: (e) {
                    if (widget.state.laser) _laserMove(e.localPosition);
                  },
                  onPointerUp: (_) => _up(),
                  onPointerCancel: (_) => _up(),
                  child: CustomPaint(
                      painter: _ScenePainter(_sender.scene, _imageArea())),
                ),
              )),
        ),
        Positioned(
            bottom: 24,
            left: 12,
            right: 12,
            child: Center(child: _Palette(ffi: widget.ffi, state: widget.state))),
      ]),
    );
  }
}

class _Palette extends StatelessWidget {
  final FFI ffi;
  final VantarisDrawState state;
  const _Palette({required this.ffi, required this.state});

  @override
  Widget build(BuildContext context) {
    Widget dot(Color c) => Obx(() => Tooltip(
          message: 'Color',
          child: InkWell(
            onTap: () {
              state.color.value = c;
              if (state.laser) state.setTool(VantarisTool.pen);
            },
            child: Container(
              width: 22,
              height: 22,
              margin: const EdgeInsets.symmetric(horizontal: 3),
              decoration: BoxDecoration(
                color: c,
                shape: BoxShape.circle,
                border: Border.all(
                    color: Colors.white, width: state.color.value == c ? 3 : 1),
              ),
            ),
          ),
        ));
    Widget width(int w, int i) => Obx(() => _button(
          Icon(Icons.circle, size: 6.0 + i * 5),
          'Grosor ${['fino', 'normal', 'grueso'][i]}',
          state.width.value == w,
          () => state.width.value = w,
        ));
    return Material(
      color: Colors.black.withOpacity(0.75),
      borderRadius: BorderRadius.circular(22),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            for (final t in VantarisTool.values)
              Obx(() => _button(Icon(_toolInfo[t]!.$1, size: 20), _toolInfo[t]!.$2,
                  state.tool.value == t, () => state.setTool(t))),
            _sep(),
            ...kVantarisDrawColors.map(dot),
            _sep(),
            for (var i = 0; i < kVantarisDrawWidths.length; i++)
              width(kVantarisDrawWidths[i], i),
            _sep(),
            Obx(() => _button(
                Icon(state.pinned.isTrue ? Icons.push_pin : Icons.push_pin_outlined,
                    size: 20),
                state.pinned.isTrue
                    ? 'Fijado: no se borra solo. Pulsa para que desaparezca'
                    : 'Fijar: que lo dibujado no se borre solo',
                state.pinned.isTrue,
                () => state.setPinned(state.pinned.isFalse))),
            Obx(() => state.focusOn.isTrue
                ? _button(const Icon(Icons.center_focus_weak, size: 20), 'Quitar el foco',
                    false, state.focusOff)
                : const SizedBox.shrink()),
            _button(const Icon(Icons.photo_camera_outlined, size: 20),
                'Captura con el dibujo, para el ticket (G)', false,
                () => vantarisCaptureAnnotated(ffi, state.sender.scene)),
            _button(const Icon(Icons.undo, size: 20), 'Deshacer (Ctrl+Z)', false,
                state.sender.undo),
            _button(const Icon(Icons.delete_sweep, size: 20), 'Borrar todo (Supr)', false,
                state.clear),
            _button(const Icon(Icons.close, size: 20),
                'Cerrar la pizarra y volver a controlar (Esc)', false, state.toggle),
          ]),
        ),
      ),
    );
  }
}

Widget _sep() => Container(
    width: 1, height: 22, margin: const EdgeInsets.symmetric(horizontal: 6),
    color: Colors.white24);

Widget _button(Widget icon, String tooltip, bool selected, VoidCallback onTap) =>
    IconButton(
      tooltip: tooltip,
      onPressed: onTap,
      visualDensity: VisualDensity.compact,
      color: selected ? const Color(0xFF03B5A5) : Colors.white70,
      icon: icon,
    );

class _ScenePainter extends CustomPainter {
  final VantarisScene scene;
  final Rect? area;
  _ScenePainter(this.scene, this.area);

  @override
  void paint(Canvas canvas, Size size) {
    final a = area;
    if (a != null) scene.paint(canvas, a);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}
