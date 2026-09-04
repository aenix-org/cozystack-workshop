# Lab 7 · Build-Rezept für das Image des Dienstes «Пропуск», Version v2.
#
# Ein Dockerfile ist eine Liste von Schritten, aus denen aus dem Quellcode ein Image entsteht: ein
# unveränderlicher Abzug des Dateisystems zusammen mit dem Startbefehl. Die naheliegendste bekannte
# Analogie ist eine Vorlage für eine virtuelle Maschine, doch sie wird nicht mit der Maus, sondern
# mit genau diesem Text gebaut, liegt in einer Registry und wird über ein Tag versioniert.
#
# Gebaut wird es auf einer VM, nicht im Cluster (siehe den Build-Schritt im README):
#   docker build --platform linux/amd64 -t <euer-harbor>/passes/passes-api:v2 app/
#   docker push  <euer-harbor>/passes/passes-api:v2
#
# --platform linux/amd64 ist auf einem Mac mit Apple Silicon zwingend: ohne ihn wird das Image
# für ARM gebaut, ohne die geringste Klage gepusht und stürzt im Cluster mit «exec format error» ab.
#
# Zweistufiger Build.
#
# Die erste Stufe ist die Build-Stufe: hier wird der ganze Go-Compiler gebraucht, das sind etwa 350 MB.
# Die zweite Stufe ist das, was in den Cluster geht: dorthin gelangt nur das fertige Binary.
# So wird das endgültige Image etwa 10 MB statt 350 groß, und darin gibt es weder
# einen Compiler noch Quellen noch einen Paketmanager — also nichts, was
# demjenigen nützt, der es doch in den Container geschafft hat.

# FROM — von welchem fertigen Image wir ausgehen. Hier nehmen wir das offizielle Image mit dem
# Go-Compiler auf Basis von Alpine. AS build gibt dieser Stufe einen Namen, damit die zweite Stufe
# das Ergebnis daraus holen kann. Die Version ist festgepinnt (1.23), nicht latest: sonst kann der
# morgige Build derselben Quelle ein anderes Binary ergeben.
FROM golang:1.23-alpine AS build
# WORKDIR — der Arbeitsordner im Image. Alle folgenden Befehle laufen in ihm.
WORKDIR /src
# COPY legt Dateien von der VM in das Image. In zwei Zeilen, nicht einer: go.mod ändert sich
# selten, main.go oft, und docker cacht jeden Schritt einzeln. Fasst man nur main.go an —
# wird der go.mod-Schritt aus dem Cache genommen.
COPY go.mod ./
COPY main.go ./
# RUN — einen Befehl direkt während des Builds ausführen; sein Ergebnis bleibt im Image.
# CGO_ENABLED=0 — statisch bauen, ohne Bindung an Systembibliotheken.
# Ohne das würde das Binary glibc benötigen, die im endgültigen Image nicht vorhanden sein wird.
# -trimpath entfernt Pfade von eurer VM aus dem Binary, -ldflags="-s -w" wirft die
# Debug-Informationen weg — das Image wird kleiner, und eure Ordnernamen gelangen nicht ins Log.
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/passes-api .

# Das zweite FROM beginnt das Image von vorn, mit einem leeren Blatt. Alles, was in der build-Stufe
# war, wird an dieser Stelle verworfen, und in das endgültige Image gelangt nur das, was wir mit dem
# nächsten Befehl COPY --from=build ausdrücklich kopieren.
FROM alpine:3.21
# Die Anwendung läuft nicht als root. In einem richtig konfigurierten Cluster wird ein Pod als root
# gar nicht zugelassen, und das ist keine Erbsenzählerei, sondern eine übliche Sicherheitsanforderung.
RUN adduser -D -u 10001 app
# Das Einzige, was aus der Build-Stufe übersiedelt, ist eine einzige Datei: das fertige Binary.
COPY --from=build /out/passes-api /usr/local/bin/passes-api
# USER — als wer der Prozess laufen soll. Angegeben ist eine Nummer, kein Name: kubernetes prüft
# im Manifest genau die Nummer (runAsNonRoot schaut auf die uid), und sie müssen zusammenpassen.
USER 10001
# EXPOSE — ein Vermerk «auf diesem Port wird intern gelauscht». Es öffnet und leitet nichts weiter,
# es ist Dokumentation für denjenigen, der das Manifest schreiben wird.
EXPOSE 8080
# ENTRYPOINT — was gestartet wird, wenn der Container startet. Der Prozess hier ist einer und er ist
# der Haupt-Prozess: endet er — endet der Container, und der Cluster bringt eine neue Kopie hoch.
ENTRYPOINT ["/usr/local/bin/passes-api"]
