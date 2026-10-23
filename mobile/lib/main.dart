import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';

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
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff125b87)),
      useMaterial3: true,
      scaffoldBackgroundColor: const Color(0xfff4f7fa),
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
  const Home({super.key});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> with WidgetsBindingObserver {
  final api = Api();
  final loginName = TextEditingController();
  final loginPassword = TextEditingController();
  Map<String, dynamic>? user, day;
  List<dynamic> users = [], groups = [];
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
    return Scaffold(
      appBar: AppBar(
        title: const Text('Protores'),
        actions: [
          IconButton(
            tooltip: 'Cambiar contraseña',
            onPressed: changePassword,
            icon: const Icon(Icons.lock_outline),
          ),
          IconButton(
            tooltip: 'Cerrar sesión',
            onPressed: busy ? null : logout,
            icon: const Icon(Icons.logout),
          ),
        ],
      ),
      body: Column(
        children: [
          if (connectionError != null)
            MaterialBanner(
              content: Text(
                'Sin sincronización. Datos posiblemente desactualizados. $connectionError',
              ),
              actions: [
                TextButton(onPressed: refresh, child: const Text('Reintentar')),
              ],
            ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () async {
                await refresh();
                if (isAdmin) {
                  await loadAdmin();
                }
              },
              child: ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  Text(
                    'I. E. Cristóbal Colón · Mariano Ramos',
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                  Text(
                    'Hola, ${user!['name']}',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  Text(
                    '${{'admin': 'Administrador', 'teacher': 'Docente', 'student': 'Estudiante'}[user!['role']]} · ${day?['date'] ?? today}',
                  ),
                  const SizedBox(height: 16),
                  if (page == 0) ...statusScreen() else ...adminScreen(),
                  if (lastSync != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 16),
                      child: Text(
                        'Última sincronización: ${DateFormat('HH:mm:ss').format(lastSync!)}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
      bottomNavigationBar: isAdmin
          ? NavigationBar(
              selectedIndex: page,
              onDestinationSelected: (v) {
                setState(() => page = v);
                if (v == 1) {
                  loadAdmin();
                }
              },
              destinations: const [
                NavigationDestination(
                  icon: Icon(Icons.restaurant),
                  label: 'Turnos',
                ),
                NavigationDestination(
                  icon: Icon(Icons.settings),
                  label: 'Administrar',
                ),
              ],
            )
          : null,
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
                const Icon(
                  Icons.restaurant_menu,
                  size: 72,
                  color: Color(0xff125b87),
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
  List<Widget> statusScreen() {
    final current = active;
    final pending = turns.where((t) => t['status'] == 'pending').toList();
    final canFinish =
        current != null &&
        (isAdmin ||
            (user!['role'] == 'teacher' &&
                current['teacher_id'] == user!['id']));
    return [
      Card(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                statusName(day?['status']),
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 16),
              Text(
                current?['group_name'] ??
                    (day?['status'] == 'finished'
                        ? '¡Jornada terminada!'
                        : 'Esperando el inicio'),
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              if (current != null) ...[
                const SizedBox(height: 16),
                Text(
                  countdown(remaining(current)),
                  style: Theme.of(context).textTheme.displayLarge,
                ),
                Text(
                  day?['status'] == 'paused'
                      ? 'Contador en pausa'
                      : remaining(current) <= 0
                      ? 'Tiempo excedido · esperando confirmación docente'
                      : 'Tiempo restante',
                ),
              ],
              const SizedBox(height: 20),
              Text(
                pending.isEmpty
                    ? 'No hay más grupos pendientes'
                    : 'Sigue: ${pending.first['group_name']}',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              if (canFinish) ...[
                const SizedBox(height: 20),
                FilledButton.icon(
                  onPressed:
                      busy ||
                          connectionError != null ||
                          day?['status'] != 'running'
                      ? null
                      : () => command('/turns/${current['id']}/finish'),
                  icon: const Icon(Icons.check_circle_outline),
                  label: const Text('Finalizar atención y llamar al siguiente'),
                ),
              ],
            ],
          ),
        ),
      ),
      if (isAdmin && day != null && day!['id'] != 0 && day!['id'] != null)
        Wrap(
          spacing: 8,
          children: [
            if (day!['status'] == 'scheduled')
              FilledButton(
                onPressed: busy || connectionError != null
                    ? null
                    : () => command('/admin/service-days/${day!['id']}/start'),
                child: const Text('Iniciar jornada'),
              ),
            if (day!['status'] == 'running')
              OutlinedButton(
                onPressed: busy || connectionError != null
                    ? null
                    : () => command('/admin/service-days/${day!['id']}/pause'),
                child: const Text('Pausar'),
              ),
            if (day!['status'] == 'paused')
              FilledButton(
                onPressed: busy || connectionError != null
                    ? null
                    : () => command('/admin/service-days/${day!['id']}/resume'),
                child: const Text('Reanudar'),
              ),
          ],
        ),
      const SizedBox(height: 16),
      Text(
        'Programación del día',
        style: Theme.of(context).textTheme.titleLarge,
      ),
      if (turns.isEmpty)
        const Padding(
          padding: EdgeInsets.all(16),
          child: Text('El administrador aún no ha programado los grupos.'),
        ),
      for (final t in turns)
        Card(
          child: ListTile(
            leading: Icon(
              t['status'] == 'active'
                  ? Icons.restaurant
                  : Icons.groups_outlined,
              color: t['status'] == 'active' ? Colors.green : null,
            ),
            title: Text(t['group_name']),
            subtitle: Text(
              '${clock(t['scheduled'])} · ${t['duration_seconds'] ~/ 60} min · ${statusName(t['status'])}',
            ),
            trailing:
                isAdmin && (t['status'] == 'pending' || t['status'] == 'active')
                ? PopupMenuButton<String>(
                    enabled:
                        !busy &&
                        connectionError == null &&
                        day?['status'] != 'paused',
                    onSelected: (action) => turnReason(t, action),
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'skip', child: Text('Omitir')),
                      PopupMenuItem(value: 'cancel', child: Text('Cancelar')),
                    ],
                  )
                : null,
          ),
        ),
      const SizedBox(height: 12),
      const Text(
        'Ingresa al restaurante cuando tu grupo aparezca en atención. Respeta la fila y las indicaciones del docente.',
      ),
    ];
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
      label: const Text('Programar jornada'),
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
        trailing: u['id'] == user!['id']
            ? null
            : PopupMenuButton<String>(
                onSelected: (action) => manageUser(u, action),
                itemBuilder: (_) => [
                  PopupMenuItem(
                    value: 'toggle',
                    child: Text(u['active'] ? 'Desactivar' : 'Activar'),
                  ),
                  const PopupMenuItem(
                    value: 'password',
                    child: Text('Restablecer contraseña'),
                  ),
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
    final selected = <int>[];
    final ids = await showDialog<List<int>>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, setLocal) => AlertDialog(
          title: const Text('Grupos en orden de atención'),
          content: SizedBox(
            width: 360,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('Selecciona en el orden en que serán llamados.'),
                  for (final g in groups.where((g) => g['active'] == true))
                    CheckboxListTile(
                      title: Text(g['name']),
                      subtitle: selected.contains(g['id'])
                          ? Text('Turno ${selected.indexOf(g['id']) + 1}')
                          : null,
                      value: selected.contains(g['id']),
                      onChanged: (v) => setLocal(() {
                        v == true
                            ? selected.add(g['id'])
                            : selected.remove(g['id']);
                      }),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c),
              child: const Text('Volver'),
            ),
            FilledButton(
              onPressed: selected.isEmpty
                  ? null
                  : () => Navigator.pop(c, List<int>.from(selected)),
              child: const Text('Continuar'),
            ),
          ],
        ),
      ),
    );
    if (ids == null || !mounted) {
      return;
    }
    final data = await fieldsDialog('Horario · Colombia', {
      'date': 'Fecha (AAAA-MM-DD), hoy: $today',
      'start': 'Inicio (HH:MM, 24 horas)',
      'minutes': 'Minutos por grupo (1–120)',
    });
    if (data == null) {
      return;
    }
    await save('/admin/service-days', {
      'date': data['date'],
      'start': data['start'],
      'minutes': int.tryParse(data['minutes'] ?? '') ?? 0,
      'group_ids': ids,
    });
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

  Future<void> manageUser(dynamic u, String action) async {
    if (action == 'toggle') {
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
