## 8. Iniciar sesión en el bastion

**Un solo inicio de sesión y ya estás dentro del clúster**

📍 **Dónde:** abre el panel (dashboard) en el navegador; todo lo demás ocurre por SSH en el bastion.

**Tus credenciales** (el login y la contraseña son los mismos en los tres lugares):
```
dashboard: https://dashboard.workshop.aenix.io
bastion:   ssh workshopXX@<bastion-address>
login:     workshopXX      ← tu número, te lo diré en persona
password:  ...             ← te lo diré en persona
```

Inicia sesión en el bastion — la contraseña es la misma que la del panel, **no hace falta ninguna clave SSH**:

```bash
ssh workshopXX@<bastion-address>
```

Una vez dentro, el acceso al clúster ya está configurado: el kubeconfig está en `~/.kube/config`, y `kubectl`
ve tu tenant de inmediato. **Para esto no se abre ningún navegador** — el inicio de sesión en el clúster va por
un token, sin Keycloak. Verifiquémoslo:

```bash
kubectl config current-context
kubectl get vminstance -n tenant-workshopXX
```

El primer comando muestra `tenant-workshopXX`; el segundo responde `No resources found`. Esa es la
respuesta correcta: todavía no hay máquinas, pero el clúster ya te reconoce.

⚠️ `kubectl get vm` y `kubectl get vmi` no funcionarán — bajo tu cuenta el tipo disponible es
`vminstance`. Así está diseñado.

⚠️ El panel en el navegador (para los pasos visuales con el ratón) usa el mismo login y la misma contraseña. Pero
el kubeconfig del panel (`Info → Secrets → kubeconfig-tenant-workshopXX`) **no** hace falta
descargarlo en el bastion: allí está pensado para el inicio de sesión desde el navegador, mientras que el bastion ya tiene
uno listo que funciona sin él.
