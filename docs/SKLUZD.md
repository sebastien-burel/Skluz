# skluzd — tunnels Système sans session ouverte

`skluzd` est le service système de Skluz. Lancé par launchd en root dès le
démarrage du Mac (après le déverrouillage FileVault, avant toute ouverture de
session), il ouvre et surveille les tunnels en mode **Système**. L'app de barre
de menus le pilote via XPC ; la commande `skluz` permet de le consulter en SSH.

Les tunnels en mode **Session** restent gérés par l'app, comme en v1.

## Fonctionnement

| Élément | Rôle |
|---|---|
| `Skluz.app/Contents/MacOS/skluzd` | Le daemon, lancé par launchd (root, `KeepAlive`). |
| `Skluz.app/Contents/Library/LaunchDaemons/net.haruni.skluzd.plist` | Déclaration launchd, enregistrée par l'app via `SMAppService`. |
| `Skluz.app/Contents/Helpers/skluz` | CLI de statut, liée depuis `/usr/local/bin/skluz`. |
| XPC `net.haruni.skluzd.xpc` | Accepte seulement Skluz et `skluz` signés par l'équipe Haruni ; modifications réservées aux administrateurs. |

Le daemon ne lance ssh qu'avec une liste blanche d'options (`-F /dev/null`,
`BatchMode`, `StrictHostKeyChecking=yes`, clé dédiée, écoute sur
`127.0.0.1`…) : aucune option libre ne peut lui être transmise.

Si ses fichiers sont mal protégés (propriétaire autre que root, droits trop
larges, lien symbolique), il **reste actif mais n'ouvre aucun tunnel**, et
affiche la commande de correction dans le menu et dans `skluz status`.

## Fichiers

```
/Library/Application Support/Skluz/      root:wheel 755
├── tunnels.json                          root:wheel 600   tunnels Système
├── keys/                                 root:wheel 700   clés dédiées (600, .pub 644)
├── known_hosts                           root:wheel 644   clés d'hôte approuvées
└── runtime.json                                           PID des ssh, pour les réadopter
/usr/local/bin/skluz                      → /Applications/Skluz.app/Contents/Helpers/skluz
```

## Prérequis

- Skluz dans **`/Applications`**, **au nom de root** : launchd retient
  l'emplacement de l'app, et une app modifiable par l'utilisateur permettrait
  d'y glisser un autre `skluzd` lancé en root. L'activation est refusée sinon.
- Un compte **administrateur** pour piloter le service.
- **Une session graphique, une seule fois**, pour approuver le service dans
  Réglages Système (sur le Mac mini : une connexion VNC). Ensuite, plus aucune
  session n'est nécessaire.
- Pour un démarrage sans session : déverrouillage FileVault par SSH.

## Installation

```sh
sudo ditto Skluz.app /Applications/Skluz.app       # depuis le DMG monté
sudo chown -R root:wheel /Applications/Skluz.app
sudo chmod -R go-w /Applications/Skluz.app
open /Applications/Skluz.app
```

1. Préférences → Service système → **Activer**, puis autoriser Skluz dans
   Réglages Système → Général → Ouverture et extensions.
2. **Installer dans /usr/local/bin** pour la commande `skluz`.
3. Pour chaque tunnel à garder sans session : l'éditer et choisir le mode
   **Système**, ou passer par « Passer des tunnels en mode Système… ».
   - **Clé dédiée** : en générer une par tunnel et ajouter la ligne copiée dans
     `~/.ssh/authorized_keys` du serveur. Elle est restreinte à ce seul tunnel
     (`restrict,port-forwarding,permitopen="…",command="/bin/false"`).
   - **Clé d'hôte** : récupérer les empreintes, les comparer à celles du
     serveur (`ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub`), approuver.

## Mise à jour

```sh
sudo rm -rf /Applications/Skluz.app
sudo ditto Skluz.app /Applications/Skluz.app
sudo chown -R root:wheel /Applications/Skluz.app && sudo chmod -R go-w /Applications/Skluz.app
```

Rien à quitter ni à désactiver : le daemon et l'app surveillent leur propre
binaire. Dès qu'il est remplacé, le daemon quitte **sans couper ses tunnels** ;
launchd démarre alors le nouveau `skluzd`, qui réadopte les ssh en cours. L'app
se relance d'elle-même depuis le nouveau bundle. En dernier recours, l'app
installée demande aussi à un daemon d'une autre version de se relancer.

Vérifier avec `skluz status` : la première ligne donne la version et le build
du service.

**Exception** : un daemon antérieur à la build 43 n'a pas cette surveillance.
Pour passer d'une telle version à une version récente, désactiver le service,
quitter Skluz, remplacer l'app, la relancer et réactiver le service.

## Désinstallation

Préférences → Service système → **Supprimer le service système…** :

- *garder la configuration* : le service s'arrête, ses fichiers restent pour
  une réactivation ultérieure ;
- *supprimer aussi la configuration* : tunnels, clés dédiées, `known_hosts` et
  `/usr/local/bin/skluz` sont effacés. Les clés sont perdues : retirer aussi
  leurs lignes des `authorized_keys` côté serveur.

## Diagnostic

```sh
skluz status                 # tableau des tunnels Système
skluz status --json
skluz check; echo $?         # 0 si tous les tunnels Système activés sont up
sudo launchctl print system/net.haruni.skluzd | grep -E 'state|pid'
/usr/bin/log show --last boot --info --predicate 'subsystem == "net.haruni.skluzd"'
sudo lsof -nP -iTCP -sTCP:LISTEN | grep ssh
sudo sfltool dumpbtm | grep -B3 -A8 skluzd
```

| Symptôme | Cause et remède |
|---|---|
| État `hostKeyUnknown` | Clé d'hôte jamais approuvée : éditer le tunnel, étape 2. |
| État `hostKeyChanged` | La clé du serveur a changé : **ne rien approuver** avant d'avoir compris pourquoi (réinstallation du serveur ou attaque). |
| `Permission denied (publickey)` | La ligne `authorized_keys` de la clé dédiée manque côté serveur. |
| Up mais « le serveur refuse la redirection » | `permitopen` de la clé ne correspond pas à l'hôte et au port distants. |
| Up mais « aucun service n'écoute » | Rien n'écoute sur le port distant côté serveur. |
| Bandeau « configuration refusée » | Fichiers mal protégés : exécuter la commande affichée. |
| Activation : « Operation not permitted » | Voir « Pièges ». |

## Pièges constatés

- **App ou daemon tournant depuis un bundle remplacé** : macOS ne relie plus
  le processus à son bundle (activation refusée : « Operation not permitted »,
  état « Introuvable dans l'app ») et sa signature n'est plus vérifiable, donc
  l'XPC est refusé (« Couldn't communicate with a helper application »). Depuis
  la build 43, les deux se relancent seuls ; sinon, les Préférences proposent
  **Relancer Skluz**.
- **Copies parasites dans LaunchServices** (Corbeille, builds Xcode) : même
  symptôme possible. Les retirer :
  ```sh
  LSR=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
  $LSR -dump | awk '/^path:/ {p=$0} /^identifier: +net.haruni.skluz$/ {print p}'
  $LSR -u "<chemin d'une copie parasite>"
  $LSR -f /Applications/Skluz.app
  ```
- **`log` sous zsh** est une commande interne : écrire `/usr/bin/log`.
- **`lsof` sans `sudo`** ne montre pas les ssh de root : utiliser `sudo lsof`,
  ou `skluz status`.
