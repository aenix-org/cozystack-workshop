# Lab 6 · Ihre eigene private Image-Registry. Build-Rezept für das Image des Dienstes «Пропуск».
#
# Was ein Dockerfile ist: ein schrittweises Rezept, aus dem aus Quellcode ein Image entsteht —
# ein startfertiges Abbild des Dateisystems zusammen mit der Angabe, was darin ausgeführt wird.
# Das Nächstliegende in vSphere ist der Bau einer goldenen VM-Vorlage, nur als Text beschrieben und
# wiederholbar: dasselbe Rezept liefert auf jeder Maschine dasselbe Ergebnis.
#
# Wird auf Ihrer VM gebaut, aus dem Lab-Ordner (das letzte Argument ist der Ordner mit dieser
# Datei und den Quellen):
#     docker build --platform linux/amd64 -t HARBOR-HOST/passes/passes-api:v1 app/
#     docker push HARBOR-HOST/passes/passes-api:v1
# Ersetzen Sie HARBOR-HOST durch die Adresse Ihres eigenen Harbor: der erste Teil des Image-Namens ist die
# Registry-Adresse, und daran erkennt docker push, wohin gesendet werden soll.
#
# ACHTUNG: --platform linux/amd64 ist auf einem Mac mit Apple-Silicon-Prozessor und auf jeder
# ARM-VM zwingend erforderlich. Ohne ihn erhalten Sie ein ARM-Image: es baut ohne Fehler, wird
# ohne Fehler in die Registry gepusht und stürzt dann im Cluster (dessen Knoten x86 sind) mit «exec format error» ab.
#
# Jede Zeile des Rezepts erzeugt eine Schicht (Layer) — einen unveränderlichen Ausschnitt des Dateisystems. Schichten
# werden zwischengespeichert und wiederverwendet: deshalb werden Dateien einzeln kopiert statt des ganzen
# Ordners auf einmal — das Bearbeiten von main.go erzwingt kein erneutes Herunterladen der Abhängigkeiten.
#
# ZWEI STUFEN. Die erste ist die Build-Stufe: sie benötigt den gesamten Go-Compiler, etwa 350 MB.
# Die zweite ist das, was in den Cluster geht: nur das fertige Binary wird übernommen.
# Das resultierende Image wird am Ende etwa 10 MB groß statt 350, und darin gibt es keinen Compiler,
# keine Quellen und keinen Paketmanager — also nichts, was jemand nutzen könnte, der es
# trotzdem in den Container geschafft hat.

# --- Stufe 1: Build -----------------------------------------------------------------
# FROM — mit welchem fertigen Image wir beginnen. Hier ist es das offizielle Image mit dem Go-Compiler
# auf Alpine (einem minimalen Linux, wenige Megabyte). Die Version ist fixiert: mit dem
# latest-Tag würde dasselbe Rezept ein halbes Jahr später etwas anderes bauen.
# AS build — der Name der Stufe, über den die zweite Stufe das Ergebnis abholt.
FROM golang:1.23-alpine AS build
# Arbeitsordner im Image: nachfolgende Befehle laufen relativ dazu.
# Wenn der Ordner nicht existiert, wird er erstellt.
WORKDIR /src
# go.mod — die Modulbeschreibung: Name und Go-Version. Die Anwendung hat keine externen Abhängigkeiten,
# daher gibt es nichts aus dem Internet herunterzuladen, und der Build läuft dort, wo es keinen Zugang nach außen gibt.
COPY go.mod ./
# Der Quellcode selbst. Wird in einer eigenen Zeile kopiert, damit das Bearbeiten des Codes den Cache
# der vorherigen Schicht nicht ungültig macht.
COPY main.go ./
# RUN führt einen Befehl beim Build aus (nicht beim Start) und speichert das Ergebnis als Schicht.
#   CGO_ENABLED=0  statisch bauen, ohne Bindung an Systembibliotheken. Ohne dies
#                  bräuchte das Binary glibc, die im endgültigen Image nicht vorhanden ist,
#                  und der Container würde beim Start scheitern, nicht beim Build
#   -trimpath      Build-Maschinen-Pfade aus dem Binary entfernen: der Build wird
#                  reproduzierbar, und der Name Ihres Home-Ordners gelangt nicht nach außen
#   -ldflags="-s -w"  die Debug-Tabellen verwerfen — die Datei wird deutlich kleiner
#   -o /out/...    wohin das Ergebnis gelegt wird; von dort holt es die zweite Stufe ab
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/passes-api .

# --- Stufe 2: das, was in den Cluster geht -----------------------------------------------
# Das zweite FROM beginnt das Image neu, von einem leeren Blatt: alles, was in der ersten Stufe angesammelt wurde,
# bleibt dort und gelangt nicht in das endgültige Image.
FROM alpine:3.21
# Wir legen den Benutzer an, unter dem die Anwendung laufen wird: als root darf sie nicht laufen.
# In einem korrekt konfigurierten Cluster würde ein Pod als root gar nicht zugelassen, und das ist keine
# Spitzfindigkeit, sondern eine übliche Sicherheitsanforderung.
#   -D          ohne Passwort erstellen, ohne Nachfragen
#   -u 10001    numerischer Identifikator; der Cluster prüft genau die Zahl, nicht den Namen
RUN adduser -D -u 10001 app
# Das Einzige, was aus der ersten Stufe übernommen wird, ist das fertige Binary. --from=build
# verweist auf den Namen der Stufe. /usr/local/bin ist ein Ordner, der im PATH jedes Linux existiert.
COPY --from=build /out/passes-api /usr/local/bin/passes-api
# Ab dieser Stelle läuft der Prozess im Container unter Benutzer 10001, nicht unter root.
# Die Reihenfolge ist wichtig: die Zeilen oben liefen als root, sonst hätte adduser nicht funktioniert.
USER 10001
# Port-Deklaration — ein Hinweis für Menschen und Werkzeuge. Sie öffnet den Port nicht
# und konfiguriert nichts: der Zugang dazu ist im Manifest (passes.yaml) beschrieben.
EXPOSE 8080
# Was beim Start des Containers ausgeführt wird. In Listenform statt als Zeichenkette: so wird der Befehl
# direkt ausgeführt, ohne eine zwischengeschaltete Shell, und das Stopp-Signal vom Cluster
# erreicht die Anwendung selbst, nicht die Shell, die sie erzeugt hat.
ENTRYPOINT ["/usr/local/bin/passes-api"]
