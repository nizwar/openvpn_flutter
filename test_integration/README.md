# Test d'intégration OpenVPN Flutter (Windows)

Ce projet permet de tester le bon fonctionnement du plugin `openvpn_flutter` sur Windows.

## Prérequis

- **Windows 10/11**
- **Flutter** installé et configuré pour Windows
- **Droits administrateur** (OpenVPN nécessite des privilèges élevés pour créer des interfaces TAP/TUN)
- **Connexion internet**
- **Fichier de configuration .ovpn valide**
- **TAP/TUN adapter installé** (normalement fourni avec OpenVPN)

## Configuration

Avant de lancer les tests, modifiez les constantes dans `lib/main.dart` :

```dart
static const String testConfigPath = r'C:\chemin\vers\votre\config.ovpn';
static const String testUsername = 'votre_username';
static const String testPassword = 'votre_password';
```

## Exécution

1. Ouvrez un terminal **en tant qu'administrateur**

2. Naviguez vers ce dossier :
   ```powershell
   cd C:\Users\info18\Dev\openvpn_flutter\test_integration
   ```

3. Récupérez les dépendances :
   ```powershell
   flutter pub get
   ```

4. Lancez l'application de test :
   ```powershell
   flutter run -d windows
   ```

5. Dans l'application, cliquez sur **"Lancer les tests"**

## Tests effectués

| # | Test | Description |
|---|------|-------------|
| 1 | Vérification plateforme | Vérifie que le test s'exécute sur Windows |
| 2 | Déploiement binaire | Déploie `openvpn.exe` depuis les assets ou le télécharge |
| 3 | Vérification binaire | Vérifie que `openvpn.exe` existe et est accessible |
| 4 | Lecture fichier .ovpn | Lit et valide le fichier de configuration |
| 5 | Initialisation plugin | Initialise le plugin OpenVPN |
| 6 | Connexion VPN | Établit une connexion VPN |
| 7 | Vérification stage connecté | Vérifie que le stage est "connected" |
| 8 | Récupération status | Récupère les statistiques de connexion |
| 9 | Déconnexion VPN | Ferme la connexion VPN |
| 10 | Vérification stage déconnecté | Vérifie que le stage est "disconnected" |

## Résolution de problèmes

### Le test de connexion échoue

- Vérifiez que le fichier .ovpn est valide
- Vérifiez les identifiants (username/password)
- Vérifiez que le serveur VPN est accessible
- Assurez-vous d'exécuter en tant qu'administrateur

### Le déploiement du binaire échoue

- Vérifiez que le fichier `openvpn.exe.bin` est présent dans `assets/openvpn/windows/`
- Vérifiez la connexion internet (si le téléchargement est nécessaire)

### Erreur "TAP adapter not found"

- Installez le driver TAP/TUN fourni avec OpenVPN
- Ou installez OpenVPN GUI qui inclut le driver

## Structure

```
test_integration/
├── lib/
│   └── main.dart          # Application de test
├── windows/               # Configuration Windows Flutter
├── pubspec.yaml          # Dépendances
└── README.md             # Ce fichier
```
