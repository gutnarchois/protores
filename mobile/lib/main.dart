import 'dart:async';
import 'dart:convert';
import 'schedule_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

const apiBase = String.fromEnvironment(
  'API_BASE_URL',
  defaultValue: 'https://restaurante.in4.blue/api/v1',
);
const storage = FlutterSecureStorage();
void main() {
  runApp(const ProtoresApp());
}

class ProtoresApp extends StatelessWidget {
  const ProtoresApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Protores',
    locale: const Locale('es', 'CO'),
    supportedLocales: const [Locale('es', 'CO')],
    localizationsDelegates: const [
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff139c61)),
      useMaterial3: true,
      scaffoldBackgroundColor: const Color(0xfff7f9fd),
      inputDecorationTheme: const InputDecorationTheme(
        border: OutlineInputBorder(),
      ),
      cardTheme: const CardThemeData(margin: EdgeInsets.symmetric(vertical: 8)),
    ),
    home: const Home(),
  );
}

class ApiException implements Exception {
  final String message;
  final int code;
  ApiException(this.message, this.code);
  @override
  String toString() => message;
}

class Api {
  String? token;
  Future<dynamic> call(
    String path, {
    String method = 'GET',
    Map<String, dynamic>? data,
  }) async {
    final uri = Uri.parse('$apiBase$path');
    if (uri.scheme != 'https' &&
        uri.host != '127.0.0.1' &&
        uri.host != '10.0.2.2') {
      throw ApiException('La conexión requiere HTTPS', 0);
    }
    final response = http.Request(method, uri)
      ..headers.addAll({
        'Content-Type': 'application/json',
        if (token != null) 'Authorization': 'Bearer $token',
      })
      ..body = data == null ? '' : jsonEncode(data);
    final result = await http.Response.fromStream(
      await response.send().timeout(const Duration(seconds: 12)),
    ).timeout(const Duration(seconds: 12));
    dynamic value;
    try {
      value = jsonDecode(result.body);
    } catch (_) {
      throw ApiException('Respuesta no válida del servidor', result.statusCode);
    }
    if (result.statusCode >= 400) {
      throw ApiException(
        value['error'] ?? 'No se pudo completar',
        result.statusCode,
      );
    }
    return value;
  }
}

class Home extends StatefulWidget {
  const Home({super.key, this.api});
  final Api? api;
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> with WidgetsBindingObserver {
  late final Api api = widget.api ?? Api();
  final loginName = TextEditingController();
  final loginPassword = TextEditingController();
  Map<String, dynamic>? user, day;
  List<dynamic> users = [], groups = [], students = [];
  String search = '';
  int? selectedGroup;
  String? attendanceError;
  bool get staff => isAdmin || user?['role'] == 'teacher';
  String? error;
  String? connectionError;
  DateTime? lastSync;
  bool busy = false, loading = true, refreshing = false, foreground = true;
  int page = 0;
  Duration serverOffset = Duration.zero;
  Timer? poll, tick;
  DateTime get serverNow => DateTime.now().toUtc().add(serverOffset);
  String get today => DateFormat(
    'yyyy-MM-dd',
  ).format(serverNow.subtract(const Duration(hours: 5)));
  bool get isAdmin => user?['role'] == 'admin';
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    restore();
    poll = Timer.periodic(const Duration(seconds: 5), (_) {
      if (user != null && foreground) {
        refresh();
      }
    });
    tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && foreground) {
        setState(() {});
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    foreground = state == AppLifecycleState.resumed;
    if (foreground && user != null) {
      refresh();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    poll?.cancel();
    tick?.cancel();
    loginName.dispose();
    loginPassword.dispose();
    super.dispose();
  }

  Future<void> restore() async {
    try {
      api.token = await storage.read(key: 'token');
      if (api.token != null) {
        user = Map<String, dynamic>.from(await api.call('/me'));
        await refresh();
      }
    } catch (_) {
      api.token = null;
      user = null;
      await storage.delete(key: 'token');
    }
    if (mounted) {
      setState(() => loading = false);
    }
  }

  Future<void> logout() async {
    try {
      await api.call('/auth/logout', method: 'POST');
    } catch (_) {
      /* Local logout remains available offline. */
    }
    await storage.delete(key: 'token');
    api.token = null;
    if (mounted) {
      setState(() {
        user = null;
        day = null;
        users = [];
        groups = [];
        students = [];
        selectedGroup = null;
        search = '';
        attendanceError = null;
        page = 0;
        error = null;
        connectionError = null;
      });
    }
  }

  Future<void> login() async {
    if (busy) {
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final value = await api.call(
        '/auth/login',
        method: 'POST',
        data: {
          'username': loginName.text.trim(),
          'password': loginPassword.text,
        },
      );
      api.token = value['token'];
      await storage.write(key: 'token', value: api.token);
      loginPassword.clear();
      if (!mounted) {
        return;
      }
      setState(() {
        user = Map<String, dynamic>.from(value['user']);
      });
      await refresh();
    } catch (e) {
      if (mounted) {
        setState(() => error = readError(e));
      }
    } finally {
      if (mounted) {
        setState(() => busy = false);
      }
    }
  }

  String readError(Object e) => e is ApiException
      ? e.message
      : 'Sin conexión. Revisa tu red e intenta nuevamente.';
  Future<void> refresh() async {
    if (refreshing || user == null) {
      return;
    }
    refreshing = true;
    try {
      final result = await api.call('/status');
      if (!mounted) {
        return;
      }
      setState(() {
        day = Map<String, dynamic>.from(result['day']);
        serverOffset = DateTime.parse(
          result['server_time'],
        ).difference(DateTime.now().toUtc());
        lastSync = DateTime.now();
        connectionError = null;
      });
      if (staff) await loadStudents();
    } catch (e) {
      if (e is ApiException && e.code == 401) {
        await storage.delete(key: 'token');
        api.token = null;
        if (mounted) {
          setState(() {
            user = null;
            day = null;
            error = 'Tu sesión venció. Vuelve a ingresar.';
          });
        }
      } else if (mounted) {
        setState(() => connectionError = readError(e));
      }
    } finally {
      refreshing = false;
    }
  }

  Future<void> loadAdmin() async {
    try {
      final values = await Future.wait([
        api.call('/admin/users'),
        api.call('/admin/groups'),
      ]);
      if (mounted) {
        setState(() {
          users = values[0];
          groups = values[1];
        });
      }
    } catch (e) {
      showMessage(readError(e));
    }
  }

  void showMessage(String text) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
    }
  }

  Future<bool> confirm(String title, String text) async =>
      await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text(title),
          content: Text(text),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Volver'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Confirmar'),
            ),
          ],
        ),
      ) ??
      false;
  Future<void> command(String path, {String? reason}) async {
    if (busy || connectionError != null || day == null) {
      return;
    }
    if (!await confirm(
      'Confirmar acción',
      'El cambio se mostrará a todos los usuarios conectados.',
    )) {
      return;
    }
    if (!mounted) {
      return;
    }
    setState(() => busy = true);
    try {
      await api.call(
        path,
        method: 'POST',
        data: {
          'date': day!['date'],
          'version': day!['version'],
          'reason': reason ?? '',
        },
      );
      await refresh();
    } catch (e) {
      showMessage(readError(e));
      await refresh();
    } finally {
      if (mounted) {
        setState(() => busy = false);
      }
    }
  }

  List<dynamic> get turns => day?['turns'] as List<dynamic>? ?? [];
  Map<String, dynamic>? get active {
    for (final t in turns) {
      if (t['status'] == 'active') {
        return Map<String, dynamic>.from(t);
      }
    }
    return null;
  }

  String statusName(String? s) =>
      {
        'unconfigured': 'Sin programación',
        'scheduled': 'Pendiente de inicio',
        'running': 'En atención',
        'paused': 'Jornada pausada',
        'finished': 'Finalizado',
        'pending': 'Pendiente',
        'active': 'En el restaurante',
        'skipped': 'Omitido',
        'cancelled': 'Cancelado',
      }[s] ??
      s ??
      '';
  int remaining(Map<String, dynamic> t) {
    if (t['started_at'] == null) {
      return t['duration_seconds'];
    }
    final end = day?['paused_at'] != null
        ? DateTime.parse(day!['paused_at'])
        : serverNow;
    return (t['duration_seconds'] -
            (end.difference(DateTime.parse(t['started_at'])).inMilliseconds /
                    1000 -
                (t['paused_seconds'] as num)))
        .ceil();
  }

  String countdown(int n) {
    n = n < 0 ? 0 : n;
    return '${(n ~/ 60).toString().padLeft(2, '0')}:${(n % 60).toString().padLeft(2, '0')}';
  }

  String clock(String value) => DateFormat(
    'HH:mm',
  ).format(DateTime.parse(value).toUtc().subtract(const Duration(hours: 5)));
  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (user == null) {
      return loginScreen();
    }
    final accent = [
      const Color(0xff15995d),
      const Color(0xff237be5),
      const Color(0xff7356e9),
      const Color(0xfff58a0b),
    ][page];
    return Theme(
      data: Theme.of(context).copyWith(
        colorScheme: ColorScheme.fromSeed(
          seedColor: accent,
        ).copyWith(primary: accent, onPrimary: Colors.white),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            minimumSize: const Size(0, 48),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
          ),
        ),
        navigationBarTheme: NavigationBarThemeData(
          backgroundColor: Colors.white,
          indicatorColor: accent.withValues(alpha: 0.12),
        ),
      ),
      child: Scaffold(
        appBar: AppBar(
          backgroundColor: accent,
          foregroundColor: Colors.white,
          toolbarHeight: 80,
          leading: page == 0
              ? Padding(
                  padding: const EdgeInsets.all(8),
                  child: Image.asset(
                    'assets/images/protores-logo.png',
                    semanticLabel: 'Logo de Protores',
                  ),
                )
              : Icon(
                  page == 0
                      ? Icons.restaurant_menu
                      : page == 1
                      ? Icons.schedule
                      : page == 2
                      ? Icons.qr_code_scanner
                      : Icons.settings,
                ),
          title: Text(
            [
              'Protores',
              'Turno actual',
              'Registro de ingreso',
              'Panel del encargado',
            ][page],
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 20),
          ),
          actions: [
            IconButton(
              tooltip: 'Actualizar',
              onPressed: refresh,
              icon: const Icon(Icons.refresh),
            ),
            PopupMenuButton<String>(
              onSelected: (v) => v == 'password' ? changePassword() : logout(),
              itemBuilder: (_) => const [
                PopupMenuItem(
                  value: 'password',
                  child: Text('Cambiar contraseña'),
                ),
                PopupMenuItem(value: 'logout', child: Text('Cerrar sesión')),
              ],
            ),
          ],
        ),
        body: Column(
          children: [
            if (connectionError != null)
              MaterialBanner(
                content: Text('Sin sincronización. $connectionError'),
                actions: [
                  TextButton(
                    onPressed: refresh,
                    child: const Text('Reintentar'),
                  ),
                ],
              ),
            Expanded(
              child: RefreshIndicator(
                onRefresh: refresh,
                child: ListView(
                  key: ValueKey(page),
                  padding: const EdgeInsets.all(16),
                  children: [
                    Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 640),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (page == 0) ...welcomeScreen(),
                            if (page == 1) ...statusScreen(),
                            if (page == 2) ...registrationScreen(),
                            if (page == 3) ...managerScreen(),
                            if (lastSync != null)
                              Padding(
                                padding: const EdgeInsets.only(top: 16),
                                child: Text(
                                  'Actualizado: ${DateFormat('HH:mm:ss').format(lastSync!)}',
                                  textAlign: TextAlign.center,
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: page,
          onDestinationSelected: (v) {
            setState(() => page = v);
            if (v == 3 && isAdmin) loadAdmin();
            if (staff && v >= 2) loadStudents();
          },
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.home_outlined),
              selectedIcon: Icon(Icons.home),
              label: 'Inicio',
            ),
            NavigationDestination(
              icon: Icon(Icons.schedule),
              label: 'Turno actual',
            ),
            NavigationDestination(
              icon: Icon(Icons.qr_code_scanner),
              label: 'Registro',
            ),
            NavigationDestination(
              icon: Icon(Icons.person_outline),
              selectedIcon: Icon(Icons.person),
              label: 'Encargado',
            ),
          ],
        ),
      ),
    );
  }

  Widget loginScreen() => Scaffold(
    body: Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: AutofillGroup(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Image.asset(
                  'assets/images/protores-logo.png',
                  height: 108,
                  semanticLabel: 'Logo de Protores',
                ),
                const SizedBox(height: 16),
                Text(
                  'Protores',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.displaySmall,
                ),
                const SizedBox(height: 8),
                const Text(
                  'Cada grupo, a su tiempo.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                const Text(
                  'PAE · Cristóbal Colón · Mariano Ramos',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 32),
                TextField(
                  controller: loginName,
                  autofillHints: const [AutofillHints.username],
                  decoration: const InputDecoration(labelText: 'Usuario'),
                  textInputAction: TextInputAction.next,
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: loginPassword,
                  obscureText: true,
                  autofillHints: const [AutofillHints.password],
                  decoration: const InputDecoration(labelText: 'Contraseña'),
                  onSubmitted: (_) => login(),
                ),
                const SizedBox(height: 20),
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(
                      error!,
                      style: const TextStyle(color: Colors.red),
                    ),
                  ),
                FilledButton(
                  onPressed: busy ? null : login,
                  child: Text(busy ? 'Ingresando…' : 'Ingresar'),
                ),
                const SizedBox(height: 20),
                const Text(
                  'Solicita tu cuenta al administrador de la institución.',
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  Widget panel(
    String title,
    IconData icon,
    List<Widget> children, {
    Color? color,
  }) => Card(
    color: color ?? Colors.white,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(18),
      side: const BorderSide(color: Color(0xffe9edf4)),
    ),
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(icon, color: const Color(0xff123461)),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.bold,
                    color: Color(0xff0a2350),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          ...children,
        ],
      ),
    ),
  );

  List<Widget> welcomeScreen() => [
    ClipRRect(
      borderRadius: BorderRadius.circular(18),
      child: Image.asset(
        'assets/images/restaurante-escolar.png',
        height: 140,
        width: double.infinity,
        fit: BoxFit.cover,
        semanticLabel:
            'Estudiantes recibiendo su almuerzo en el restaurante escolar',
      ),
    ),
    const SizedBox(height: 8),
    panel('¡Bienvenido, ${user!['name']}!', Icons.waving_hand_outlined, const [
      Text(
        'Consulta los horarios de turnos y las normas del restaurante escolar.',
        textAlign: TextAlign.center,
      ),
    ], color: const Color(0xffe9f3ff)),
    panel('Horarios de turnos', Icons.schedule, scheduleRows()),
    panel('Normas del restaurante', Icons.assignment_outlined, [
      for (final rule in [
        'Respeta tu turno.',
        'Mantén el orden en la fila.',
        'No ingreses con alimentos externos.',
        'Deposita la basura en su lugar.',
        'Sigue las indicaciones del personal.',
      ])
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Row(
            children: [
              const Icon(
                Icons.check_circle,
                color: Color(0xff15995d),
                size: 20,
              ),
              const SizedBox(width: 10),
              Expanded(child: Text(rule)),
            ],
          ),
        ),
    ]),
  ];

  List<Widget> scheduleRows() => [
    if (turns.isEmpty) const Text('Aún no hay turnos programados para hoy.'),
    for (final t in turns)
      Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: t['status'] == 'active'
              ? const Color(0xffd4f5df)
              : [
                  const Color(0xfffff0c2),
                  const Color(0xffd9ecff),
                  const Color(0xffd4f5df),
                  const Color(0xffffdce0),
                  const Color(0xffe7dfff),
                  const Color(0xffd4f4fa),
                ][turns.indexOf(t) % 6],
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            Expanded(
              flex: 3,
              child: Text(
                '${clock(t['scheduled'])} – ${clock(DateTime.parse(t['scheduled']).add(Duration(seconds: t['duration_seconds'] as int)).toIso8601String())}',
                style: const TextStyle(fontSize: 12),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              flex: 2,
              child: Text(
                t['group_name'],
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              flex: 2,
              child: Text(
                t['status'] == 'active' ? 'En curso' : statusName(t['status']),
                textAlign: TextAlign.right,
                style: const TextStyle(fontSize: 11),
              ),
            ),
          ],
        ),
      ),
  ];

  List<Widget> statusScreen() {
    final current = active;
    final pending = turns.where((t) => t['status'] == 'pending').toList();
    final seconds = current == null
        ? 0
        : remaining(current).clamp(0, current['duration_seconds'] as int);
    return [
      panel('En este momento se atiende:', Icons.groups, [
        Text(
          current?['group_name'] ?? statusName(day?['status']),
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 44,
            fontWeight: FontWeight.w800,
            color: Color(0xff0a2350),
          ),
        ),
        const SizedBox(height: 10),
        const Text(
          'TURNO ACTUAL',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: Color(0xff15995d),
            fontWeight: FontWeight.bold,
          ),
        ),
      ], color: const Color(0xffe0f6e8)),
      panel('Siguiente turno:', Icons.groups_outlined, [
        Text(
          pending.isEmpty
              ? 'No hay turnos pendientes'
              : pending.first['group_name'],
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 32, fontWeight: FontWeight.bold),
        ),
      ], color: const Color(0xffedf5ff)),
      if (current != null)
        panel('Tiempo restante del turno actual', Icons.timer_outlined, [
          LinearProgressIndicator(
            value: seconds / (current['duration_seconds'] as int),
            minHeight: 12,
            borderRadius: BorderRadius.circular(12),
            color: const Color(0xff2dbf78),
          ),
          const SizedBox(height: 12),
          Text(
            '${countdown(remaining(current))} · ${day?['status'] == 'paused'
                ? 'En pausa'
                : remaining(current) <= 0
                ? 'Tiempo excedido'
                : '${current['duration_seconds'] ~/ 60} minutos en total'}',
          ),
          if (isAdmin ||
              (user?['role'] == 'teacher' &&
                  current['teacher_id'] == user?['id']))
            FilledButton(
              onPressed:
                  busy || connectionError != null || day?['status'] != 'running'
                  ? null
                  : () => command('/turns/${current['id']}/finish'),
              child: const Text('Finalizar atención y llamar al siguiente'),
            ),
        ]),
      panel('Horario completo', Icons.schedule, scheduleRows()),
    ];
  }

  Future<void> loadStudents() async {
    try {
      final result = await api.call('/students');
      if (mounted && staff) {
        setState(() {
          students = result;
          attendanceError = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => attendanceError = readError(e));
    }
  }

  Future<void> registerCode(String code) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      final result = await api.call(
        '/attendance',
        method: 'POST',
        data: {'code': code},
      );
      showMessage('Ingreso registrado: ${result['name']}');
      await loadStudents();
    } catch (e) {
      showMessage(readError(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> scanCode() async {
    final code = await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (_) => const ScannerScreen()),
    );
    if (code != null && mounted) await registerCode(code);
  }

  Widget studentRow(dynamic s, {bool register = false}) => ListTile(
    contentPadding: EdgeInsets.zero,
    leading: Icon(
      s['registered_at'] == null ? Icons.person_outline : Icons.check_circle,
      color: s['registered_at'] == null
          ? Colors.blueGrey
          : const Color(0xff15995d),
    ),
    title: Text(s['name']),
    subtitle: Text('${s['group_name']} · ${s['code']}'),
    trailing: s['registered_at'] != null
        ? Text(clock(s['registered_at']))
        : register
        ? TextButton(
            onPressed: busy || connectionError != null
                ? null
                : () => registerCode(s['code']),
            child: const Text('Registrar'),
          )
        : const Text('Pendiente'),
  );

  List<Widget> registrationScreen() {
    if (!staff) {
      return [
        panel('Registro de ingreso', Icons.lock_outline, const [
          Text(
            'El registro de estudiantes está disponible para docentes y administradores.',
          ),
        ]),
      ];
    }
    final recent = students.where((s) => s['registered_at'] != null).toList()
      ..sort(
        (a, b) => (b['registered_at'] as String).compareTo(
          a['registered_at'] as String,
        ),
      );
    return [
      panel('Escanear código', Icons.qr_code_scanner, [
        const Icon(Icons.qr_code_scanner, size: 88, color: Color(0xff344895)),
        const SizedBox(height: 16),
        const Text(
          'Acerca el código QR del estudiante para registrar su ingreso.',
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: busy || connectionError != null ? null : scanCode,
          child: const Text('ESCANEAR'),
        ),
      ], color: const Color(0xffefecff)),
      if (attendanceError != null)
        Text(attendanceError!, style: const TextStyle(color: Colors.red)),
      TextField(
        decoration: const InputDecoration(
          prefixIcon: Icon(Icons.search),
          hintText: 'Buscar estudiante por nombre o código…',
        ),
        onChanged: (v) => setState(() => search = v.trim().toLowerCase()),
      ),
      if (search.isNotEmpty)
        panel('Resultados de búsqueda', Icons.search, [
          for (final s in students.where(
            (s) => '${s['name']} ${s['code']}'.toLowerCase().contains(search),
          ))
            studentRow(s, register: true),
          if (!students.any(
            (s) => '${s['name']} ${s['code']}'.toLowerCase().contains(search),
          ))
            const Text('No se encontraron estudiantes.'),
        ]),
      panel('Últimos registros', Icons.history, [
        if (recent.isEmpty) const Text('Aún no hay ingresos registrados hoy.'),
        for (final s in recent.take(10)) studentRow(s),
      ]),
    ];
  }

  List<Widget> managerScreen() {
    if (!staff) {
      return [
        panel('Panel del encargado', Icons.lock_outline, const [
          Text('Acceso reservado al personal autorizado.'),
        ]),
      ];
    }
    final available = <int, String>{
      for (final g in groups.where((g) => g['active'] == true))
        g['id'] as int: g['name'] as String,
      for (final t in turns.where(
        (t) => isAdmin || t['teacher_id'] == user?['id'],
      ))
        t['group_id'] as int: t['group_name'] as String,
      for (final s in students) s['group_id'] as int: s['group_name'] as String,
    };
    final roster = students
        .where((s) => selectedGroup == null || s['group_id'] == selectedGroup)
        .toList();
    final count = roster.where((s) => s['registered_at'] != null).length;
    return [
      if (isAdmin)
        panel('Control de turnos', Icons.schedule, [
          Text(
            'Turno actual: ${active?['group_name'] ?? 'Sin turno activo'}',
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 12),
          if (active != null)
            FilledButton(
              onPressed:
                  busy || connectionError != null || day?['status'] != 'running'
                  ? null
                  : () => command('/turns/${active!['id']}/finish'),
              child: const Text('CAMBIAR TURNO'),
            ),
          const SizedBox(height: 12),
          Text(
            'Siguiente turno: ${turns.where((t) => t['status'] == 'pending').map((t) => t['group_name']).firstOrNull ?? 'Sin turnos pendientes'}',
          ),
          if (day?['status'] == 'scheduled')
            FilledButton(
              onPressed: busy
                  ? null
                  : () => command('/admin/service-days/${day!['id']}/start'),
              child: const Text('Iniciar jornada'),
            ),
          ExpansionTile(
            title: const Text('Más controles de turnos'),
            children: [
              if (day?['status'] == 'running')
                OutlinedButton(
                  onPressed: busy
                      ? null
                      : () =>
                            command('/admin/service-days/${day!['id']}/pause'),
                  child: const Text('Pausar jornada'),
                ),
              if (day?['status'] == 'paused')
                FilledButton(
                  onPressed: busy
                      ? null
                      : () =>
                            command('/admin/service-days/${day!['id']}/resume'),
                  child: const Text('Reanudar jornada'),
                ),
              for (final t in turns.where(
                (t) => t['status'] == 'pending' || t['status'] == 'active',
              ))
                ListTile(
                  title: Text(t['group_name']),
                  trailing: PopupMenuButton<String>(
                    enabled:
                        !busy &&
                        connectionError == null &&
                        day?['status'] != 'paused',
                    onSelected: (v) => turnReason(t, v),
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'skip', child: Text('Omitir turno')),
                      PopupMenuItem(
                        value: 'cancel',
                        child: Text('Cancelar turno'),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ]),
      panel('Estudiantes registrados', Icons.groups, [
        if (attendanceError != null)
          Text(attendanceError!, style: const TextStyle(color: Colors.red)),
        DropdownButtonFormField<int>(
          initialValue: available.containsKey(selectedGroup)
              ? selectedGroup
              : null,
          decoration: const InputDecoration(labelText: 'Curso'),
          items: [
            const DropdownMenuItem<int>(
              value: null,
              child: Text('Todos los cursos'),
            ),
            for (final e in available.entries)
              DropdownMenuItem(value: e.key, child: Text(e.value)),
          ],
          onChanged: (v) => setState(() => selectedGroup = v),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: attendanceStat(
                'Registrados',
                count,
                const Color(0xffdff7e7),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: attendanceStat(
                'Total esperado',
                roster.length,
                const Color(0xffeff2f7),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        LinearProgressIndicator(
          value: roster.isEmpty ? 0 : count / roster.length,
          minHeight: 14,
          borderRadius: BorderRadius.circular(10),
          color: const Color(0xff15995d),
        ),
        const SizedBox(height: 8),
        Text(
          '${roster.isEmpty ? 0 : (count * 100 / roster.length).round()}% de asistencia',
          textAlign: TextAlign.right,
        ),
        ExpansionTile(
          title: const Text('Ver lista de estudiantes'),
          children: [
            if (roster.isEmpty)
              const Text('No hay estudiantes creados para este curso.'),
            for (final s in roster) studentRow(s),
          ],
        ),
      ]),
      if (isAdmin) ...[
        OutlinedButton.icon(
          onPressed: busy ? null : createStudent,
          icon: const Icon(Icons.person_add_alt),
          label: const Text('Crear estudiante'),
        ),
        ...adminScreen(),
      ],
    ];
  }

  Widget attendanceStat(String label, int count, Color color) => Container(
    padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(12),
    ),
    child: Column(
      children: [
        Text(
          label,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 12),
        ),
        Text(
          '$count',
          style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
        ),
      ],
    ),
  );

  Future<void> createStudent() async {
    if (groups.isEmpty) {
      showMessage('Crea primero un grupo.');
      return;
    }
    final name = TextEditingController(), code = TextEditingController();
    int group = groups.first['id'];
    final result = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Crear estudiante'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: name,
                maxLength: 120,
                decoration: const InputDecoration(labelText: 'Nombre'),
              ),
              TextField(
                controller: code,
                maxLength: 80,
                decoration: const InputDecoration(
                  labelText: 'Código único (contenido del QR)',
                ),
              ),
              DropdownButtonFormField<int>(
                initialValue: group,
                items: [
                  for (final g in groups)
                    DropdownMenuItem(
                      value: g['id'] as int,
                      child: Text(g['name']),
                    ),
                ],
                onChanged: (v) => group = v!,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () {
              if (name.text.trim().isNotEmpty && code.text.trim().isNotEmpty) {
                Navigator.pop(c, true);
              }
            },
            child: const Text('Guardar'),
          ),
        ],
      ),
    );
    if (result == true && mounted) {
      setState(() => busy = true);
      try {
        await api.call(
          '/students',
          method: 'POST',
          data: {
            'name': name.text.trim(),
            'code': code.text.trim(),
            'group_id': group,
          },
        );
        await loadStudents();
        showMessage('Estudiante creado');
      } catch (e) {
        showMessage(readError(e));
      } finally {
        if (mounted) setState(() => busy = false);
      }
    }
    // The closing route may still be animating when the dialog future completes.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    name.dispose();
    code.dispose();
  }

  List<Widget> adminScreen() => [
    Text(
      'Organiza la jornada',
      style: Theme.of(context).textTheme.headlineSmall,
    ),
    const SizedBox(height: 12),
    FilledButton.icon(
      onPressed: busy ? null : createSchedule,
      icon: const Icon(Icons.calendar_month),
      label: const Text('Programar / editar jornada'),
    ),
    if (day?['id'] != null && day?['id'] != 0 && day?['status'] != 'finished')
      OutlinedButton.icon(
        onPressed: busy ? null : () => editSchedule(today),
        icon: const Icon(Icons.edit_calendar),
        label: const Text('Editar horarios de hoy'),
      ),

    OutlinedButton.icon(
      onPressed: busy ? null : createUser,
      icon: const Icon(Icons.person_add),
      label: const Text('Crear usuario'),
    ),
    OutlinedButton.icon(
      onPressed: busy ? null : createGroup,
      icon: const Icon(Icons.group_add),
      label: const Text('Crear grupo'),
    ),
    OutlinedButton.icon(
      onPressed: showAudit,
      icon: const Icon(Icons.history),
      label: const Text('Ver historial'),
    ),
    const SizedBox(height: 20),
    Text(
      'Grupos (${groups.length})',
      style: Theme.of(context).textTheme.titleLarge,
    ),
    for (final g in groups)
      ListTile(
        title: Text(g['name']),
        subtitle: Text(
          'Docente: ${users.where((u) => u['id'] == g['teacher_id']).map((u) => u['name']).join()}',
        ),
      ),
    const SizedBox(height: 16),
    Text(
      'Usuarios (${users.length})',
      style: Theme.of(context).textTheme.titleLarge,
    ),
    for (final u in users)
      ListTile(
        title: Text(u['name']),
        subtitle: Text(
          '${u['username']} · ${u['role']} · ${u['active'] ? 'Activo' : 'Inactivo'}',
        ),
        onTap: busy ? null : () => editUser(u),
        trailing: PopupMenuButton<String>(
          enabled: !busy,
          tooltip: 'Opciones de usuario',
          onSelected: (action) => manageUser(u, action),
          itemBuilder: (_) => [
            const PopupMenuItem(value: 'edit', child: Text('Editar usuario')),
            if (u['id'] != user!['id']) ...[
              PopupMenuItem(
                value: 'toggle',
                child: Text(u['active'] ? 'Desactivar' : 'Activar'),
              ),
              const PopupMenuItem(
                value: 'password',
                child: Text('Restablecer contraseña'),
              ),
            ],
          ],
        ),
      ),
  ];
  Future<Map<String, String>?> fieldsDialog(
    String title,
    Map<String, String> labels, {
    Set<String> secret = const {},
  }) async {
    final controllers = {
      for (final e in labels.entries) e.key: TextEditingController(),
    };
    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final e in labels.entries)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: TextField(
                    controller: controllers[e.key],
                    obscureText: secret.contains(e.key),
                    decoration: InputDecoration(labelText: e.value),
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('Volver'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, {
              for (final e in controllers.entries)
                e.key: secret.contains(e.key)
                    ? e.value.text
                    : e.value.text.trim(),
            }),
            child: const Text('Guardar'),
          ),
        ],
      ),
    );
    // Wait for the closing route animation before disposing controllers.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    for (final c in controllers.values) {
      c.dispose();
    }
    return result;
  }

  Future<void> save(
    String path,
    Map<String, dynamic> data, {
    String method = 'POST',
  }) async {
    if (busy) {
      return;
    }
    if (mounted) {
      setState(() => busy = true);
    }
    try {
      await api.call(path, method: method, data: data);
      showMessage('Guardado');
      await loadAdmin();
      await refresh();
    } catch (e) {
      showMessage(readError(e));
    } finally {
      if (mounted) {
        setState(() => busy = false);
      }
    }
  }

  Future<void> createUser() async {
    String? role = await showDialog<String>(
      context: context,
      builder: (c) => SimpleDialog(
        title: const Text('Tipo de usuario'),
        children: [
          for (final e in {
            'teacher': 'Docente',
            'student': 'Estudiante',
            'admin': 'Administrador',
          }.entries)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(c, e.key),
              child: Text(e.value),
            ),
        ],
      ),
    );
    if (role == null || !mounted) {
      return;
    }
    final data = await fieldsDialog(
      'Crear usuario',
      {
        'name': 'Nombre',
        'username': 'Usuario',
        'password': 'Contraseña (mínimo 12 caracteres)',
      },
      secret: {'password'},
    );
    if (data == null) {
      return;
    }
    await save('/admin/users', {...data, 'role': role});
  }

  Future<void> createGroup() async {
    final teachers = users
        .where((u) => u['role'] == 'teacher' && u['active'] == true)
        .toList();
    if (teachers.isEmpty) {
      showMessage('Primero crea un docente activo.');
      return;
    }
    final id = await showDialog<int>(
      context: context,
      builder: (c) => SimpleDialog(
        title: const Text('Docente responsable'),
        children: [
          for (final t in teachers)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(c, t['id']),
              child: Text(t['name']),
            ),
        ],
      ),
    );
    if (id == null || !mounted) {
      return;
    }
    final data = await fieldsDialog('Crear grupo', {
      'name': 'Grado y grupo (ej. 6-1)',
    });
    if (data != null) {
      await save('/admin/groups', {...data, 'teacher_id': id});
    }
  }

  Future<void> createSchedule() async {
    if (groups.isEmpty) {
      showMessage('Primero crea los grupos y sus docentes.');
      return;
    }
    final now = DateTime.parse(today);
    final selected = await showDatePicker(
      context: context,
      initialDate: now,
      firstDate: now,
      lastDate: now.add(const Duration(days: 730)),
      helpText: 'Selecciona la jornada a crear o editar',
    );
    if (selected == null || !mounted) return;
    await editSchedule(DateFormat('yyyy-MM-dd').format(selected));
  }

  Future<void> editSchedule(String date) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      final value = await api.call('/schedule?date=$date');
      final scheduled = Map<String, dynamic>.from(value['day']);
      if (scheduled['status'] == 'finished') {
        showMessage('La jornada ya terminó; se conserva su historial.');
        return;
      }
      if (!mounted) return;
      final saved = await Navigator.push<bool>(
        context,
        MaterialPageRoute(
          builder: (_) => ScheduleEditor(
            date: date,
            groups: groups,
            turns: scheduled['turns'] as List<dynamic>? ?? [],
            onSave: (turns) async {
              final exists = scheduled['id'] != null && scheduled['id'] != 0;
              try {
                await api.call(
                  exists
                      ? '/admin/service-days/${scheduled['id']}'
                      : '/admin/service-days',
                  method: exists ? 'PATCH' : 'POST',
                  data: {
                    'date': date,
                    if (exists) 'version': scheduled['version'],
                    'turns': turns,
                  },
                );
              } catch (e) {
                throw ApiException(
                  readError(e),
                  e is ApiException ? e.code : 0,
                );
              }
            },
          ),
        ),
      );
      if (saved == true) {
        await refresh();
        showMessage('Horarios guardados');
      }
    } catch (e) {
      showMessage(readError(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> turnReason(dynamic turn, String action) async {
    final data = await fieldsDialog(
      action == 'skip' ? 'Omitir turno' : 'Cancelar turno',
      {'reason': 'Motivo obligatorio'},
    );
    if (data != null) {
      await command(
        '/admin/turns/${turn['id']}/$action',
        reason: data['reason'],
      );
    }
  }

  Future<void> editUser(dynamic u) async {
    if (busy) return;
    final data = await showDialog<Map<String, String>>(
      context: context,
      builder: (_) => UserEditDialog(name: u['name'], username: u['username']),
    );
    if (data == null || !mounted) return;
    await save('/admin/users/${u['id']}', data, method: 'PATCH');
    if (u['id'] == user?['id']) {
      try {
        final updated = Map<String, dynamic>.from(await api.call('/me'));
        if (mounted) setState(() => user = updated);
      } catch (e) {
        showMessage(readError(e));
      }
    }
  }

  Future<void> manageUser(dynamic u, String action) async {
    if (action == 'edit') {
      await editUser(u);
    } else if (action == 'toggle') {
      if (await confirm(
        'Cambiar acceso',
        '${u['active'] ? 'Desactivar' : 'Activar'} a ${u['name']}?',
      )) {
        await save('/admin/users/${u['id']}', {
          'active': !u['active'],
        }, method: 'PATCH');
      }
    } else {
      final data = await fieldsDialog(
        'Restablecer contraseña',
        {'password': 'Nueva contraseña (mínimo 12 caracteres)'},
        secret: {'password'},
      );
      if (data != null) {
        await save('/admin/users/${u['id']}', {
          ...data,
          'active': u['active'],
        }, method: 'PATCH');
      }
    }
  }

  Future<void> changePassword() async {
    final data = await fieldsDialog(
      'Cambiar contraseña',
      {
        'current': 'Contraseña actual',
        'password': 'Nueva contraseña (mínimo 12 caracteres)',
      },
      secret: {'current', 'password'},
    );
    if (data == null) {
      return;
    }
    try {
      await api.call('/auth/password', method: 'POST', data: data);
      showMessage('Contraseña actualizada');
    } catch (e) {
      showMessage(readError(e));
    }
  }

  Future<void> showAudit() async {
    try {
      final List<dynamic> events = await api.call('/admin/audit');
      if (!mounted) {
        return;
      }
      await showDialog<void>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('Últimas 100 acciones'),
          content: SizedBox(
            width: 500,
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final e in events)
                  ListTile(
                    title: Text('${e['actor']} · ${e['action']}'),
                    subtitle: Text(
                      '${e['created_at']}\n${jsonEncode(e['detail'])}',
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c),
              child: const Text('Cerrar'),
            ),
          ],
        ),
      );
    } catch (e) {
      showMessage(readError(e));
    }
  }
}

class UserEditDialog extends StatefulWidget {
  const UserEditDialog({super.key, required this.name, required this.username});

  final String name;
  final String username;

  @override
  State<UserEditDialog> createState() => _UserEditDialogState();
}

class _UserEditDialogState extends State<UserEditDialog> {
  final formKey = GlobalKey<FormState>();
  late final name = TextEditingController(text: widget.name);
  late final username = TextEditingController(text: widget.username);

  @override
  void dispose() {
    name.dispose();
    username.dispose();
    super.dispose();
  }

  void submit() {
    if (formKey.currentState!.validate()) {
      Navigator.pop(context, {
        'name': name.text.trim(),
        'username': username.text.trim().toLowerCase(),
      });
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Editar usuario'),
    content: SingleChildScrollView(
      child: Form(
        key: formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              controller: name,
              decoration: const InputDecoration(labelText: 'Nombre'),
              textCapitalization: TextCapitalization.words,
              textInputAction: TextInputAction.next,
              validator: (value) => value == null || value.trim().isEmpty
                  ? 'Escribe el nombre'
                  : utf8.encode(value.trim()).length > 120
                  ? 'El nombre es demasiado largo'
                  : null,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: username,
              decoration: const InputDecoration(labelText: 'Usuario de acceso'),
              autocorrect: false,
              enableSuggestions: false,
              textInputAction: TextInputAction.done,
              onFieldSubmitted: (_) => submit(),
              validator: (value) {
                final length = utf8
                    .encode(value?.trim().toLowerCase() ?? '')
                    .length;
                if (length < 3) {
                  return 'Escribe un usuario de al menos 3 caracteres';
                }
                return length > 80 ? 'El usuario es demasiado largo' : null;
              },
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancelar'),
      ),
      FilledButton(onPressed: submit, child: const Text('Guardar')),
    ],
  );
}

class ScannerScreen extends StatefulWidget {
  const ScannerScreen({super.key});
  @override
  State<ScannerScreen> createState() => _ScannerScreenState();
}

class _ScannerScreenState extends State<ScannerScreen> {
  bool detected = false;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Escanear código del estudiante')),
    body: Column(
      children: [
        Expanded(
          child: MobileScanner(
            onDetect: (capture) {
              if (detected) return;
              for (final barcode in capture.barcodes) {
                final code = barcode.rawValue;
                if (code != null && code.trim().isNotEmpty) {
                  detected = true;
                  Navigator.pop(context, code.trim());
                  break;
                }
              }
            },
            errorBuilder: (context, error) => const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'No se pudo abrir la cámara. Revisa el permiso de cámara o vuelve para buscar al estudiante por su código.',
                ),
              ),
            ),
          ),
        ),
        const Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Coloca el QR dentro de la cámara. El código debe coincidir con el del estudiante.',
          ),
        ),
      ],
    ),
  );
}
