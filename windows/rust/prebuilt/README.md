## Artefacts Rust précompilés

Ce dossier contient les bibliothèques Rust livrées avec `openvpn_flutter` pour éviter aux consommateurs d’installer Rust/rustup lors d’un build Windows classique.

### Structure attendue

```
windows/rust/prebuilt/
└── x86_64-pc-windows-msvc/
    ├── debug/
    │   ├── openvpn_flutter_rust.dll
    │   └── openvpn_flutter_rust.dll.lib
    └── release/
        ├── openvpn_flutter_rust.dll
        └── openvpn_flutter_rust.dll.lib
```

> Note: certains toolchains peuvent générer `openvpn_flutter_rust.lib` au lieu de
> `openvpn_flutter_rust.dll.lib`. Le CMake du plugin accepte les deux noms.

Seuls les binaires `release` sont nécessaires pour les builds distribués (`flutter build windows`). Les binaires `debug` sont utiles pour les tests locaux sans Rust.

### Générer/mettre à jour les binaires

1. Installer l’outilchain MSVC compatible (Visual Studio Build Tools) puis `rustup target add x86_64-pc-windows-msvc`.
2. Depuis `windows/rust/`, exécuter :

   ```powershell
   cargo build --target x86_64-pc-windows-msvc --release
   ```

   (Ajouter `--profile dev` ou omettre `--release` pour produire les binaires `debug`.)
3. Copier les fichiers générés depuis `windows/rust/target/x86_64-pc-windows-msvc/<profil>/` vers la structure `prebuilt/` ci-dessus.
   - DLL: `openvpn_flutter_rust.dll`
   - Import library: `openvpn_flutter_rust.dll.lib` (ou `openvpn_flutter_rust.lib`)
4. Commiter les binaires pour qu’ils soient distribués avec la librairie (ou publier les DLL via un artefact de release et les placer ici lors du packaging).

### Validation CI

Le workflow GitHub Actions `windows-rust-prebuilt.yml` reconstruit les artefacts
Windows et détecte les écarts avec les binaires versionnés dans `prebuilt/`.
En cas d'écart, le workflow publie un artefact `prebuilt-drift.patch` pour
inspection et mise à jour du dépôt.

### Désactiver l’usage des précompilés

Lorsqu’on développe sur le plugin et qu’on souhaite recompiler systématiquement le Rust, il suffit de désactiver l’option CMake :

```powershell
cmake -DOPENVPN_FLUTTER_USE_PREBUILT_RUST=OFF ...
```

Dans ce mode, CMake invoquera automatiquement `cargo build` et utilisera les artefacts présents dans `windows/rust/target/`.

