# Lab 7 · Build-Rezept für das Image des Dienstes «Пропуск», Version v2.
#
# Ein Dockerfile ist eine Liste von Schritten, die aus Quelltexten ein Image machen: ein unveränderliches
# Abbild eines Dateisystems zusammen mit einem Startbefehl. Die nächstliegende vertraute Analogie ist
# eine Vorlage für eine virtuelle Maschine, nur wird es nicht mit der Maus gebaut, sondern mit genau diesem Text, es liegt
# in einer Registry und wird über ein Tag versioniert.
#
# Gebaut wird es auf dem Laptop, nicht im Cluster (siehe den Build-Schritt in der README):
#   docker build --platform linux/amd64 -t <ваш-harbor>/passes/passes-api:v2 app/
#   docker push  <ваш-harbor>/passes/passes-api:v2
#
# --platform linux/amd64 ist auf einem Mac mit Apple Silicon zwingend: ohne es wird das Image
# für ARM gebaut, ohne die geringste Beschwerde gepusht und stürzt im Cluster mit «exec format error» ab.
#
# Ein zweistufiger Build.
#
# Die erste Stufe ist die Build-Stufe: sie braucht den ganzen Go-Compiler, und das sind etwa 350 MB.
# Die zweite Stufe ist das, was in den Cluster geht: dorthin gelangt nur das fertige Binary.
# So endet das finale Image bei etwa 10 MB statt 350, und in ihm gibt es weder
# einen Compiler noch Quelltexte noch einen Paketmanager — das heißt, es gibt nichts, womit
# derjenige, der es doch in den Container geschafft hat, etwas anfangen könnte.

# FROM — von welchem vorgefertigten Image wir starten. Hier nehmen wir das offizielle Image mit dem Go-
# Compiler auf Alpine-Basis. AS build gibt dieser Stufe einen Namen, damit die zweite Stufe das
# Ergebnis daraus entnehmen kann. Die Version ist festgenagelt (1.23), nicht latest: sonst kann der Build desselben
# Quelltexts von morgen ein anderes Binary erzeugen.
FROM golang:1.23-alpine AS build
# WORKDIR — das Arbeitsverzeichnis innerhalb des Images. Alle folgenden Befehle werden darin ausgeführt.
WORKDIR /src
# COPY legt Dateien vom Laptop in das Image. In zwei Zeilen, nicht in einer: go.mod ändert sich
# selten, main.go — oft, und docker cacht jeden Schritt einzeln. Nur main.go angefasst —
# der go.mod-Schritt kommt aus dem Cache.
COPY go.mod ./
COPY main.go ./
# RUN — einen Befehl direkt während des Builds ausführen; sein Ergebnis bleibt im Image.
# CGO_ENABLED=0 — statisch bauen, ohne Bindung an Systembibliotheken.
# Ohne das würde das Binary glibc benötigen, die im finalen Image nicht vorhanden sein wird.
# -trimpath entfernt Pfade von deinem Laptop aus dem Binary, -ldflags="-s -w" wirft
# Debug-Informationen weg — das Image ist kleiner, und deine Ordnernamen gelangen nicht ins Log.
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/passes-api .

# Das zweite FROM beginnt das Image von vorn, mit einem sauberen Blatt. Alles, was in der Build-Stufe war,
# wird an dieser Stelle verworfen, und in das finale Image gelangt nur das, was wir mit dem nächsten
# Befehl COPY --from=build explizit kopieren.
FROM alpine:3.21
# Die Anwendung läuft nicht als root. In einem korrekt konfigurierten Cluster wird ein Pod, der als root läuft,
# gar nicht erst zugelassen, und das ist keine Kleinlichkeit, sondern eine übliche Sicherheitsanforderung.
RUN adduser -D -u 10001 app
# Das Einzige, was aus der Build-Stufe herüberzieht, ist eine einzige Datei: das fertige Binary.
COPY --from=build /out/passes-api /usr/local/bin/passes-api
# USER — als welcher Benutzer der Prozess laufen soll. Angegeben ist eine Nummer, kein Name: kubernetes prüft
# im Manifest genau die Nummer (runAsNonRoot schaut auf die uid), und sie müssen übereinstimmen.
USER 10001
# EXPOSE — ein Vermerk, dass «auf diesem Port intern gelauscht wird». Es öffnet nichts und leitet nichts weiter,
# das ist Dokumentation für denjenigen, der das Manifest schreiben wird.
EXPOSE 8080
# ENTRYPOINT — was gestartet wird, wenn der Container startet. Es gibt hier einen einzigen Prozess und er ist
# der Hauptprozess: endet er, endet der Container, und der Cluster bringt eine neue Kopie hoch.
ENTRYPOINT ["/usr/local/bin/passes-api"]
