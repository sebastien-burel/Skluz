# Signature Developer ID & notarisation — Skluz

> Procédure à exécuter **par Sébastien** avec le compte Apple Haruni.
> Claude ne lance aucune de ces commandes (action externe + secrets).

Réglages projet déjà en place : `CODE_SIGN_STYLE = Automatic`,
`DEVELOPMENT_TEAM = 82FW35VV68`, `ENABLE_HARDENED_RUNTIME = YES`,
`ENABLE_APP_SANDBOX = NO`. Distribution **hors App Store** (Developer ID).

## 0. Prérequis (une fois)

- Certificat **« Developer ID Application »** de Haruni installé dans le trousseau
  (vérifier : `security find-identity -v -p codesigning`).
- Identifiants de notarisation, au choix :
  - **App Store Connect API key** (recommandé) : fichier `AuthKey_XXXX.p8`,
    *Key ID*, *Issuer ID* ; ou
  - Apple ID + **mot de passe d'application** dédié.
- Stocker une fois pour toutes dans le trousseau :
  ```sh
  xcrun notarytool store-credentials "skluz-notary" \
    --apple-id "holding.laduche@burel.net" \
    --team-id 82FW35VV68 \
    --password "<mot-de-passe-application>"
  ```

## 1. Archive

```sh
xcodebuild -project Skluz.xcodeproj -scheme Skluz \
  -configuration Release \
  -archivePath build/Skluz.xcarchive archive
```

## 2. Export Developer ID

`ExportOptions.plist` (déjà ignoré par git) :

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>82FW35VV68</string>
  <key>signingStyle</key><string>automatic</string>
</dict>
</plist>
```

```sh
xcodebuild -exportArchive \
  -archivePath build/Skluz.xcarchive \
  -exportOptionsPlist ExportOptions.plist \
  -exportPath build/export
```

→ produit `build/export/Skluz.app`.

## 3. Vérifier la signature

```sh
codesign --verify --deep --strict --verbose=2 build/export/Skluz.app
codesign -dvv build/export/Skluz.app 2>&1 | grep -E 'Authority|Runtime'
```

Attendu : `Authority=Developer ID Application: Haruni SAS …`, flag
`runtime` présent (Hardened Runtime).

## 4. Notariser

```sh
ditto -c -k --keepParent build/export/Skluz.app build/Skluz.zip

xcrun notarytool submit build/Skluz.zip \
  --keychain-profile "skluz-notary" --wait
```

Attendu : `status: Accepted`. En cas de `Invalid`, lire le rapport :
`xcrun notarytool log <submission-id> --keychain-profile "skluz-notary"`.

## 5. Agrafer le ticket

```sh
xcrun stapler staple build/export/Skluz.app
xcrun stapler validate build/export/Skluz.app
```

## 6. Vérification finale (Gatekeeper)

```sh
spctl -a -vvv --type execute build/export/Skluz.app
```

Attendu : `accepted` / `source=Notarized Developer ID`.

## 7. Distribution

Zipper le `.app` agrafé (ou un DMG) :

```sh
ditto -c -k --keepParent build/export/Skluz.app Skluz-1.0.zip
```

Critère plan §11 Phase 10 : copier `Skluz-1.0.zip` sur une autre machine,
le `.app` doit s'ouvrir sans avertissement Gatekeeper et l'icône menubar
écluse apparaître (pas d'icône Dock).
