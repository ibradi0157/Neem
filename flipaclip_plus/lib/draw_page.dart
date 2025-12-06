import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:ui' as ui;
import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';

enum Tool { brush, eraser }

class Stroke {
  Stroke({
    required this.points,
    required this.color,
    required this.width,
    required this.eraser,
  });

  final List<Offset> points;
  final Color color;
  final double width;
  final bool eraser;

  Map<String, dynamic> toJson() => {
        'points': points.map((p) => [p.dx, p.dy]).toList(),
        'color': color.value,
        'width': width,
        'eraser': eraser,
      };

  static Stroke fromJson(Map<String, dynamic> json) {
    final pts = (json['points'] as List)
        .map((p) => Offset((p[0] as num).toDouble(), (p[1] as num).toDouble()))
        .toList();
    return Stroke(
      points: pts,
      color: Color(json['color'] as int),
      width: (json['width'] as num).toDouble(),
      eraser: json['eraser'] as bool,
    );
  }
}

class CanvasPainter extends CustomPainter {
  CanvasPainter({required this.strokes, this.current});

  final List<Stroke> strokes;
  final Stroke? current;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.saveLayer(Offset.zero & size, Paint());

    void drawStroke(Stroke s) {
      final paint = Paint()
        ..color = s.color
        ..strokeWidth = s.width
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;

      if (s.eraser) {
        paint.blendMode = BlendMode.clear;
      }

      final pts = s.points;
      if (pts.isEmpty) return;

      if (pts.length < 2) {
        canvas.drawPoints(ui.PointMode.points, pts, paint);
        return;
      }

      final path = Path()..moveTo(pts.first.dx, pts.first.dy);
      for (int i = 1; i < pts.length; i++) {
        final p0 = pts[i - 1];
        final p1 = pts[i];
        final mid = Offset((p0.dx + p1.dx) / 2, (p0.dy + p1.dy) / 2);
        path.quadraticBezierTo(p0.dx, p0.dy, mid.dx, mid.dy);
      }
      path.lineTo(pts.last.dx, pts.last.dy);
      canvas.drawPath(path, paint);
    }

    for (final s in strokes) {
      drawStroke(s);
    }
    if (current != null) {
      drawStroke(current!);
    }

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant CanvasPainter oldDelegate) => true;
}


class DrawPage extends StatefulWidget {
  const DrawPage({super.key});

  @override
  State<DrawPage> createState() => _DrawPageState();
}

class _DrawPageState extends State<DrawPage> {
  final GlobalKey _repaintKey = GlobalKey();
  final List<Stroke> _strokes = [];
  final List<Stroke> _redo = [];
  Stroke? _current;

  Tool _tool = Tool.brush;
  double _width = 6.0;
  Color _color = Colors.black;

  @override
  void initState() {
    super.initState();
    _loadProjectIfAny();
  }

  void _startStroke(Offset pos) {
    final stroke = Stroke(
      points: [pos],
      color: _tool == Tool.brush ? _color : const Color(0x00000000),
      width: _width,
      eraser: _tool == Tool.eraser,
    );
    setState(() {
      _current = stroke;
    });
  }

  void _addPoint(Offset pos) {
    if (_current == null) return;
    setState(() {
      _current!.points.add(pos);
    });
  }

  void _endStroke() {
    if (_current == null) return;
    setState(() {
      _strokes.add(_current!);
      _current = null;
      _redo.clear();
    });
  }

  void _undo() {
    if (_strokes.isEmpty) return;
    setState(() {
      _redo.add(_strokes.removeLast());
    });
  }

  void _redoAction() {
    if (_redo.isEmpty) return;
    setState(() {
      _strokes.add(_redo.removeLast());
    });
  }

  Future<Directory?> _projectDir() async {
    if (kIsWeb) return null; // skip file I/O on web in this phase demo
    final dir = await getApplicationDocumentsDirectory();
    final d = Directory('${dir.path}/flipaclip_plus');
    if (!await d.exists()) {
      await d.create(recursive: true);
    }
    return d;
  }

  Future<void> _saveProject() async {
    final d = await _projectDir();
    if (d == null) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Sauvegarde non supportée sur Web dans cette démo.')),
        );
      }
    } else {
      final jsonFile = File('${d.path}/current_project.json');
      final data = jsonEncode({
        'strokes': _strokes.map((s) => s.toJson()).toList(),
      });
      await jsonFile.writeAsString(data);
      await _saveThumbnail(d);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Projet sauvegardé.')),
        );
      }
    }
  }

  Future<void> _saveThumbnail(Directory d) async {
    final obj = _repaintKey.currentContext?.findRenderObject();
    if (obj is! RenderRepaintBoundary) return;
    final ui.Image image = await obj.toImage(pixelRatio: 2.0);
    final ByteData? bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    if (bytes == null) return;
    final Uint8List pngBytes = bytes.buffer.asUint8List();
    final thumbFile = File('${d.path}/current_project_thumb.png');
    await thumbFile.writeAsBytes(pngBytes, flush: true);
  }

  Future<void> _loadProjectIfAny() async {
    try {
      final d = await _projectDir();
      if (d == null) return;
      final jsonFile = File('${d.path}/current_project.json');
      if (!await jsonFile.exists()) return;
      final content = await jsonFile.readAsString();
      final decoded = jsonDecode(content) as Map<String, dynamic>;
      final loaded = (decoded['strokes'] as List)
          .map((e) => Stroke.fromJson(e as Map<String, dynamic>))
          .toList();
      setState(() {
        _strokes
          ..clear()
          ..addAll(loaded);
        _redo.clear();
        _current = null;
      });
    } catch (_) {
      // ignore malformed files for now
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Flipaclip++ — Phase 1'),
        actions: [
          IconButton(
            tooltip: 'Pinceau',
            icon: Icon(Icons.brush, color: _tool == Tool.brush ? Colors.blue : null),
            onPressed: () => setState(() => _tool = Tool.brush),
          ),
          IconButton(
            tooltip: 'Gomme',
            icon: Icon(Icons.auto_fix_off, color: _tool == Tool.eraser ? Colors.blue : null),
            onPressed: () => setState(() => _tool = Tool.eraser),
          ),
          IconButton(
            tooltip: 'Annuler',
            icon: const Icon(Icons.undo),
            onPressed: _strokes.isNotEmpty ? _undo : null,
          ),
          IconButton(
            tooltip: 'Refaire',
            icon: const Icon(Icons.redo),
            onPressed: _redo.isNotEmpty ? _redoAction : null,
          ),
          IconButton(
            tooltip: 'Sauvegarder',
            icon: const Icon(Icons.save),
            onPressed: _saveProject,
          ),
          IconButton(
            tooltip: 'Charger',
            icon: const Icon(Icons.folder_open),
            onPressed: _loadProjectIfAny,
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                const Text('Taille'),
                Expanded(
                  child: Slider(
                    value: _width,
                    min: 1,
                    max: 40,
                    onChanged: (v) => setState(() => _width = v),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.circle, color: Colors.black),
                  onPressed: () => setState(() => _color = Colors.black),
                ),
                IconButton(
                  icon: const Icon(Icons.circle, color: Colors.red),
                  onPressed: () => setState(() => _color = Colors.red),
                ),
                IconButton(
                  icon: const Icon(Icons.circle, color: Colors.blue),
                  onPressed: () => setState(() => _color = Colors.blue),
                ),
              ],
            ),
          ),
          Expanded(
            child: RepaintBoundary(
              key: _repaintKey,
              child: Container(
                color: Colors.white,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onPanStart: (d) => _startStroke(d.localPosition),
                  onPanUpdate: (d) => _addPoint(d.localPosition),
                  onPanEnd: (_) => _endStroke(),
                  child: CustomPaint(
                    painter: CanvasPainter(strokes: _strokes, current: _current),
                    size: Size.infinite,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
