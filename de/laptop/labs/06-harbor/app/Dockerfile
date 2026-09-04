# Lab 6 · Ihre eigene private Image-Registry. Build-Rezept für das Image des Dienstes «Пропуск».
#
# Was ein Dockerfile ist: ein Schritt-für-Schritt-Rezept, das aus Quellcode ein Image macht —
# ein startbereiter Schnappschuss des Dateisystems zusammen mit der Angabe, was darin ausgeführt werden soll.
# Die nächste Entsprechung in vSphere ist das Erstellen einer goldenen VM-Vorlage, nur als Text beschrieben und
# wiederholbar: dasselbe Rezept liefert auf jeder Maschine dasselbe Ergebnis.
#
# Wird auf Ihrem Laptop gebaut, aus dem Lab-Ordner (das letzte Argument ist der Ordner mit dieser
# Datei und den Quellen):
#     docker build --platform linux/amd64 -t HARBOR-HOST/passes/passes-api:v1 app/
#     docker push HARBOR-HOST/passes/passes-api:v1
# Ersetzen Sie HARBOR-HOST durch die Adresse Ihres eigenen Harbor: der erste Teil des Image-Namens ist
# die Registry-Adresse, und daran erkennt docker push, wohin es gesendet werden soll.
#
# ACHTUNG: --platform linux/amd64 ist auf einem Mac mit Apple-Silicon-Prozessor und auf jedem
# ARM-Laptop zwingend erforderlich. Ohne ihn erhalten Sie ein ARM-Image: es baut ohne Fehler, wird
# ohne Fehler in die Registry gepusht und stürzt dann im Cluster (dessen Knoten x86 sind) mit «exec format error» ab.
#
# Jede Zeile des Rezepts erzeugt eine Schicht — einen unveränderlichen Ausschnitt des Dateisystems. Schichten werden
# zwischengespeichert und wiederverwendet: deshalb werden Dateien einzeln kopiert und nicht der ganze Ordner
# auf einmal — das Bearbeiten von main.go erzwingt kein erneutes Herunterladen der Abhängigkeiten.
#
# ZWEI STUFEN. Die erste ist die Build-Stufe: hier wird der gesamte Go-Compiler benötigt, das sind etwa 350 MB.
# Die zweite ist das, was in den Cluster geht: dorthin wird nur das fertige Binary übertragen.
# Das resultierende Image wird etwa 10 MB groß statt 350, und darin gibt es weder einen Compiler
# noch Quellen noch einen Paketmanager — also nichts, was demjenigen nützt, der
# es doch in den Container schafft.

# --- Stufe 1: Build -----------------------------------------------------------------
# FROM — von welchem fertigen Image wir ausgehen. Hier ist es das offizielle Image mit dem Go-Compiler
# auf Basis von Alpine (ein minimales Linux, ein paar Megabyte). Die Version ist festgelegt: mit dem
# Tag latest würde dasselbe Rezept ein halbes Jahr später etwas anderes bauen.
# AS build — der Name der Stufe; die zweite Stufe holt sich darüber das Ergebnis.
FROM golang:1.23-alpine AS build
# Arbeitsordner innerhalb des Images: nachfolgende Befehle werden relativ dazu ausgeführt.
# Wenn der Ordner nicht existiert, wird er erstellt.
WORKDIR /src
# go.mod — die Modulbeschreibung: Name und Go-Version. Die Anwendung hat keine externen
# Abhängigkeiten, es gibt also nichts aus dem Internet herunterzuladen, und der Build läuft dort, wo es keinen Zugang nach außen gibt.
COPY go.mod ./
# Der Quellcode selbst. Wird in einer eigenen Zeile kopiert, damit das Bearbeiten des Codes den Cache
# der vorherigen Schicht nicht verwirft.
COPY main.go ./
# RUN führt einen Befehl beim Build aus (nicht beim Start) und speichert das Ergebnis als Schicht.
#   CGO_ENABLED=0  statisch bauen, ohne Bindung an Systembibliotheken. Ohne dies
#                  bräuchte das Binary glibc, die im endgültigen Image nicht vorhanden sein wird,
#                  und der Container würde beim Start abstürzen, nicht beim Build
#   -trimpath      die Pfade der Build-Maschine aus dem Binary entfernen: der Build wird
#                  reproduzierbar, und der Name Ihres Home-Ordners gelangt nicht nach außen
#   -ldflags="-s -w"  die Debug-Tabellen verwerfen — die Datei wird deutlich kleiner
#   -o /out/...    wohin das Ergebnis gelegt wird; von hier holt es die zweite Stufe ab
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/passes-api .

# --- Stufe 2: was in den Cluster geht -----------------------------------------------
# Das zweite FROM beginnt das Image von Neuem, mit einem leeren Blatt: alles, was in der ersten Stufe entstanden ist,
# bleibt dort und gelangt nicht in das endgültige Image.
FROM alpine:3.21
# Wir legen den Benutzer an, unter dem die Anwendung laufen wird: als root darf sie nicht laufen.
# In einem korrekt konfigurierten Cluster wird ein Pod, der als root läuft, gar nicht zugelassen, und das ist keine
# Spitzfindigkeit, sondern eine standardmäßige Sicherheitsanforderung.
#   -D          ohne Passwort erstellen, ohne Fragen zu stellen
#   -u 10001    numerischer Identifikator; der Cluster prüft genau die Zahl, nicht den Namen
RUN adduser -D -u 10001 app
# Das Einzige, was aus der ersten Stufe übertragen wird, ist das fertige Binary. --from=build
# verweist auf den Namen der Stufe. /usr/local/bin ist ein Ordner, der im PATH jedes Linux vorhanden ist.
COPY --from=build /out/passes-api /usr/local/bin/passes-api
# Ab dieser Stelle läuft der Prozess im Container unter dem Benutzer 10001, nicht unter root.
# Die Reihenfolge ist wichtig: die Zeilen darüber liefen als root, sonst hätte adduser nicht funktioniert.
USER 10001
# Die Port-Deklaration — ein informativer Hinweis für Menschen und Werkzeuge. Sie öffnet den Port nicht
# und konfiguriert nichts: der Zugriff darauf wird im Manifest (passes.yaml) beschrieben.
EXPOSE 8080
# Was beim Start des Containers ausgeführt wird. Als Liste statt als String: so wird der Befehl
# direkt ausgeführt, ohne zwischengeschaltete Shell, und das Stopp-Signal vom Cluster
# erreicht die Anwendung selbst und nicht die Shell, die sie gestartet hat.
ENTRYPOINT ["/usr/local/bin/passes-api"]
