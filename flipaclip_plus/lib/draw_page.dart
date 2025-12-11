import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:ui' as ui;
import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';

enum Tool { brush, eraser }

/* -------------------------------------------
 * MODEL: Stroke
 * ------------------------------------------- */

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

  static Stroke fromJson(Map<String, dynamic> json) => Stroke(
        points: (json['points'] as List)
            .map((p) => Offset((p[0] as num).toDouble(), (p[1] as num).toDouble()))
            .toList(),
        color: Color(json['color'] as int),
        width: (json['width'] as num).toDouble(),
        eraser: json['eraser'] as bool,
      );
}

/* -------------------------------------------
 * PAINTER
 * ------------------------------------------- */

class CanvasPainter extends CustomPainter {
  CanvasPainter({required this.strokes, this.current});

  final List<Stroke> strokes;
  final Stroke? current;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.saveLayer(Offset.zero & size, Paint());

    for (final stroke in strokes) {
      _drawStroke(canvas, stroke);
    }
    if (current != null) _drawStroke(canvas, current!);

    canvas.restore();
  }

  void _drawStroke(Canvas canvas, Stroke s) {
    if (s.points.isEmpty) return;

    final paint = Paint()
      ..color = s.color
      ..strokeWidth = s.width
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    /// Mode effaceur -> BlendMode.clear
    if (s.eraser) paint.blendMode = BlendMode.clear;

    if (s.points.length == 1) {
      canvas.drawPoints(ui.PointMode.points, s.points, paint);
      return;
    }

    final path = Path()..moveTo(s.points.first.dx, s.points.first.dy);

    for (int i = 1; i < s.points.length; i++) {
      final p0 = s.points[i - 1];
      final p1 = s.points[i];
      final mid = Offset(
        (p0.dx + p1.dx) / 2,
        (p0.dy + p1.dy) / 2,
      );
      path.quadraticBezierTo(p0.dx, p0.dy, mid.dx, mid.dy);
    }

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(CanvasPainter oldDelegate) =>
      oldDelegate.strokes != strokes || oldDelegate.current != current;
}

/* -------------------------------------------
 * UI: Drawing Page
 * ------------------------------------------- */

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

  /* -------------------------------------------
   * DRAWING
   * ------------------------------------------- */

  void _startStroke(Offset pos) {
    setState(() {
      _current = Stroke(
        points: [pos],
        color: _tool == Tool.brush ? _color : Colors.transparent,
        width: _width,
        eraser: _tool == Tool.eraser,
      );
    });
  }

  void _addPoint(Offset pos) {
    if (_current == null) return;
    setState(() => _current!.points.add(pos));
  }

  void _endStroke() {
    if (_current == null) return;
    setState(() {
      _strokes.add(_current!);
      _current = null;
      _redo.clear();
    });
  }

  /* -------------------------------------------
   * UNDO / REDO
   * ------------------------------------------- */

  void _undo() {
    if (_strokes.isEmpty) return;
    setState(() => _redo.add(_strokes.removeLast()));
  }

  void _redoAction() {
    if (_redo.isEmpty) return;
    setState(() => _strokes.add(_redo.removeLast()));
  }

  /* -------------------------------------------
   * SAVE / LOAD
   * ------------------------------------------- */

  Future<Directory?> _projectDir() async {
    if (kIsWeb) return null;
    final dir = await getApplicationDocumentsDirectory();
    final proj = Directory('${dir.path}/flipaclip_plus');
    if (!await proj.exists()) await proj.create(recursive: true);
    return proj;
  }

  Future<void> _saveProject() async {
    final dir = await _projectDir();
    if (dir == null) {
      _showMessage('Sauvegarde indisponible sur le Web.');
      return;
    }

    final file = File('${dir.path}/current_project.json');
    await file.writeAsString(jsonEncode({
      'strokes': _strokes.map((s) => s.toJson()).toList(),
    }));

    await _saveThumbnail(dir);
    _showMessage('Projet sauvegardé.');
  }

  Future<void> _saveThumbnail(Directory dir) async {
    final boundary = _repaintKey.currentContext?.findRenderObject()
        as RenderRepaintBoundary?;

    if (boundary == null) return;

    final img = await boundary.toImage(pixelRatio: 2.0);
    final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
    if (bytes == null) return;

    final file = File('${dir.path}/current_project_thumb.png');
    await file.writeAsBytes(bytes.buffer.asUint8List(), flush: true);
  }

  Future<void> _loadProjectIfAny() async {
    try {
      final dir = await _projectDir();
      if (dir == null) return;

      final file = File('${dir.path}/current_project.json');
      if (!await file.exists()) return;

      final jsonContent = jsonDecode(await file.readAsString());
      final strokes = (jsonContent['strokes'] as List)
          .map((e) => Stroke.fromJson(e))
          .toList();

      setState(() {
        _strokes
          ..clear()
          ..addAll(strokes);
        _redo.clear();
        _current = null;
      });
    } catch (e) {
      _showMessage('Erreur lors du chargement.');
    }
  }

  void _showMessage(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  /* -------------------------------------------
   * UI
   * ------------------------------------------- */

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Flipaclip++ — Phase 1 améliorée'),
        actions: [
          IconButton(
            tooltip: 'Pinceau',
            icon: Icon(Icons.brush,
                color: _tool == Tool.brush ? Colors.blue : null),
            onPressed: () => setState(() => _tool = Tool.brush),
          ),
          IconButton(
            tooltip: 'Gomme',
            icon: Icon(Icons.auto_fix_off,
                color: _tool == Tool.eraser ? Colors.blue : null),
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

      /* ---------------- CANVAS ---------------- */
      body: Column(
        children: [
          _buildTopBar(),
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
                    painter: CanvasPainter(
                      strokes: _strokes,
                      current: _current,
                    ),
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

  /* -------------------------------------------
   * TOOLBAR
   * ------------------------------------------- */

  Widget _buildTopBar() {
    return Padding(
      padding: const EdgeInsets.all(8.0),
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
          ..._buildColorButtons(),
        ],
      ),
    );
  }

  List<Widget> _buildColorButtons() {
    final colors = [Colors.black, Colors.red, Colors.blue, Colors.green];
    return colors
        .map((c) => IconButton(
              icon: Icon(Icons.circle, color: c),
              onPressed: () => setState(() => _color = c),
            ))
        .toList();
  }
}

