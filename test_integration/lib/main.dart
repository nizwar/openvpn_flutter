/// Test de connectivité OpenVPN pour le plugin openvpn_flutter sur Windows.
///
/// Objectif :
/// - Vérifier que le binaire openvpn.exe est disponible
/// - Initialiser le plugin
/// - Établir une connexion VPN avec un fichier .ovpn
/// - Lire le status
/// - Se déconnecter proprement
///
/// Sans UI : tout se fait automatiquement au démarrage et les résultats sont
/// écrits dans la console / les logs.
///
/// EXÉCUTION :
/// ```powershell
/// cd openvpn_flutter/test_integration
/// flutter run -d windows
/// ```

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:openvpn_flutter/openvpn_flutter.dart';
import 'package:openvpn_flutter/src/windows_binary_manager.dart';

// Configuration de test (adaptée à ton environnement)
const String _testConfigPath =
    r'C:\Users\info18\Downloads\vpn-udp-11941-cursortest-config.ovpn';
const String _testUsername = 'cursortest';
const String _testPassword = 'yt243kMBLXSj';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  debugPrint('==== OpenVPN Connectivity Test (plugin only) ====');
  final success = await _runConnectivityTest();

  debugPrint('==== Résultat global : ${success ? 'SUCCÈS' : 'ÉCHEC'} ====');

  // Petite pause pour laisser les derniers logs s'afficher
  await Future.delayed(const Duration(seconds: 2));

  // Code de sortie process (0 = OK, 1 = KO)
  exit(success ? 0 : 1);
}

Future<bool> _runConnectivityTest() async {
  // État partagé
  final logs = <String>[];
  VPNStage currentStage = VPNStage.disconnected;

  void log(String message) {
    final ts = DateTime.now().toIso8601String().substring(11, 19);
    final line = '[$ts] $message';
    logs.add(line);
    debugPrint(line);
  }

  OpenVPN? vpn;

  Future<bool> runStep(String name, Future<bool> Function() step) async {
    log('▶ $name');
    try {
      final ok = await step();
      log(ok ? '✅ $name' : '❌ $name');
      return ok;
    } catch (e, st) {
      log('❌ $name - Exception: $e');
      debugPrint(st.toString());
      return false;
    }
  }

  // 1) Vérification plateforme
  final okPlatform = await runStep('Vérification plateforme Windows', () async {
    if (!Platform.isWindows) {
      log('Ce test ne fonctionne que sous Windows.');
      return false;
    }
    log('Plateforme: ${Platform.operatingSystem} ${Platform.operatingSystemVersion}');
    return true;
  });
  if (!okPlatform) return false;

  // 2) Déploiement binaire
  final okBinary = await runStep('Déploiement binaire openvpn.exe', () async {
    try {
      final path = await WindowsBinaryManager.ensureBinary(
        onProgress: (p) => log('Progression déploiement: ${(p * 100).toStringAsFixed(1)}%'),
      );
      log('Binaire prêt: $path');
      return true;
    } catch (e) {
      log('Erreur déploiement: $e');
      return false;
    }
  });
  if (!okBinary) return false;

  // 3) Vérification binaire
  final okBinaryCheck =
      await runStep('Vérification présence binaire', () async {
    final exists = await WindowsBinaryManager.binaryExists();
    if (!exists) {
      log('openvpn.exe introuvable après déploiement.');
      return false;
    }
    final path = await WindowsBinaryManager.getBinaryPath();
    final size = await WindowsBinaryManager.getBinarySize();
    final version = await WindowsBinaryManager.getInstalledVersion();
    log('Binaire: $path');
    log('Taille: ${size != null ? "${(size / 1024 / 1024).toStringAsFixed(2)} MB" : "inconnue"}');
    log('Version: ${version ?? "inconnue"}');
    return true;
  });
  if (!okBinaryCheck) return false;

  // 4) Lecture config
  final okConfig = await runStep('Lecture configuration .ovpn', () async {
    final file = File(_testConfigPath);
    if (!await file.exists()) {
      log('Fichier OVPN introuvable: $_testConfigPath');
      return false;
    }
    final content = await file.readAsString();
    log('Config lue (${content.length} caractères).');
    if (!content.contains('remote')) {
      log('Config invalide: directive "remote" manquante.');
      return false;
    }
    if (!content.contains('<ca>') || !content.contains('</ca>')) {
      log('Config invalide: bloc <ca> manquant.');
      return false;
    }
    return true;
    });
  if (!okConfig) return false;

  // 5) Initialisation plugin
  final okInit = await runStep('Initialisation plugin OpenVPN', () async {
    vpn = OpenVPN(
      onVpnStageChanged: (stage, raw) {
        currentStage = stage;
        log('Stage: $stage ($raw)');
      },
      onVpnStatusChanged: (status) {
        log(
          'Status: durée=${status?.duration}, '
          'in=${status?.byteIn}, out=${status?.byteOut}',
        );
      },
    );

    await vpn!.initialize(
      localizedDescription: 'OpenVPN Headless Test',
      lastStage: (stage) {
        currentStage = stage;
        log('Stage initial: $stage');
      },
      lastStatus: (status) {
        log('Status initial: ${status.toJson()}');
      },
    );

    return vpn!.initialized;
  });
  if (!okInit) return false;

  // 6) Connexion
  final okConnect = await runStep('Connexion VPN', () async {
    final file = File(_testConfigPath);
    final config = await file.readAsString();

    log('Connexion avec utilisateur: $_testUsername');
    await vpn!.connect(
      config,
      'OpenVPNTest',
      username: _testUsername,
      password: _testPassword,
      certIsRequired: true,
    );

    return _waitForStage(
      () => currentStage,
      VPNStage.connected,
      timeout: const Duration(seconds: 30),
      log: log,
    );
  });
  if (!okConnect) {
    // On tente tout de même une déconnexion au cas où
    await _safeDisconnect(vpn, log);
    return false;
  }

  // 7) Lecture status
  final okStatus = await runStep('Lecture status VPN', () async {
    final status = await vpn!.status();
    log('Status final: durée=${status.duration}, in=${status.byteIn}, out=${status.byteOut}');
    return status.connectedOn != null;
  });

  // 8) Déconnexion
  final okDisconnect = await runStep('Déconnexion VPN', () async {
    await _safeDisconnect(vpn, log);
    // petite attente pour que le stage remonte
    await Future.delayed(const Duration(seconds: 2));
    final stage = await vpn!.stage();
    log('Stage après déconnexion: $stage');
    return stage == VPNStage.disconnected;
  });

  return okStatus && okDisconnect;
}

Future<void> _safeDisconnect(OpenVPN? vpn, void Function(String) log) async {
  if (vpn == null) return;
  try {
    log('Déconnexion en cours...');
    vpn.disconnect();
  } catch (e) {
    log('Erreur lors de la déconnexion: $e');
  }
}

Future<bool> _waitForStage(
  VPNStage Function() getStage,
  VPNStage target, {
  required Duration timeout,
  required void Function(String) log,
}) async {
  final completer = Completer<bool>();
  Timer? timeoutTimer;
  Timer? pollTimer;

  void check() {
    final s = getStage();
    if (s == target) {
      log('Stage cible atteint: $s');
      timeoutTimer?.cancel();
      pollTimer?.cancel();
      if (!completer.isCompleted) completer.complete(true);
    } else if (s == VPNStage.error || s == VPNStage.denied) {
      log('Stage d\'erreur détecté: $s');
      timeoutTimer?.cancel();
      pollTimer?.cancel();
      if (!completer.isCompleted) completer.complete(false);
    }
  }

  // Vérification immédiate
  check();
  if (completer.isCompleted) return completer.future;

  timeoutTimer = Timer(timeout, () {
    log('Timeout en attendant le stage $target (dernier stage = ${getStage()})');
    pollTimer?.cancel();
    if (!completer.isCompleted) completer.complete(false);
  });

  pollTimer = Timer.periodic(const Duration(milliseconds: 500), (_) => check());

  return completer.future;
}
