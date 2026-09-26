// Alta, cambios y baja de usuarios del HUB. Solo la puede usar un perfil activo con rol administrador.
import { createClient } from "npm:@supabase/supabase-js@2";

const ROLES = ["administrador", "rrhh", "comercial", "mantenimiento", "consulta"];
const BLOQUEO = "876000h"; // ~100 años: usuario desactivado

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function respuesta(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, "Content-Type": "application/json" },
  });
}

class ErrorUsuario extends Error {}

function validarRoles(roles: unknown): string[] {
  if (!Array.isArray(roles) || roles.length === 0) throw new ErrorUsuario("Elegí al menos un rol.");
  const limpios = [...new Set(roles.map(String))];
  if (limpios.some((r) => !ROLES.includes(r))) throw new ErrorUsuario("Rol inválido.");
  return limpios;
}

function validarClave(clave: unknown): string {
  if (typeof clave !== "string" || clave.length < 8) {
    throw new ErrorUsuario("La contraseña tiene que tener al menos 8 caracteres.");
  }
  return clave;
}

function validarNombre(nombre: unknown): string {
  const n = typeof nombre === "string" ? nombre.trim() : "";
  if (!n) throw new ErrorUsuario("Falta el nombre.");
  return n.slice(0, 120);
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return respuesta({ error: "Método no permitido" }, 405);

  const admin = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    { auth: { persistSession: false, autoRefreshToken: false } },
  );

  const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
  const { data: auth } = await admin.auth.getUser(token);
  const yo = auth?.user;
  if (!yo) return respuesta({ error: "Sesión inválida" }, 401);

  const { data: miPerfil } = await admin
    .from("perfiles").select("roles, activo").eq("user_id", yo.id).maybeSingle();
  if (!miPerfil?.activo || !miPerfil.roles.includes("administrador")) {
    return respuesta({ error: "Solo un administrador puede gestionar usuarios." }, 403);
  }

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return respuesta({ error: "Pedido inválido" }, 400);
  }

  try {
    switch (body.accion) {
      case "listar": {
        const { data: perfiles, error } = await admin
          .from("perfiles")
          .select("user_id, email, nombre, roles, activo, debe_cambiar_clave, created_at")
          .order("nombre");
        if (error) throw error;
        const { data: lista } = await admin.auth.admin.listUsers({ perPage: 1000 });
        const ultimos = new Map((lista?.users ?? []).map((u) => [u.id, u.last_sign_in_at]));
        return respuesta({
          usuarios: (perfiles ?? []).map((p) => ({ ...p, ultimo_ingreso: ultimos.get(p.user_id) ?? null })),
        });
      }

      case "crear": {
        const email = String(body.email ?? "").trim().toLowerCase();
        if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) throw new ErrorUsuario("Email inválido.");
        const nombre = validarNombre(body.nombre);
        const roles = validarRoles(body.roles);
        const clave = validarClave(body.clave);

        const { data: creado, error } = await admin.auth.admin.createUser({
          email,
          password: clave,
          email_confirm: true,
          user_metadata: { nombre },
        });
        if (error) {
          if (/already|registered|exists/i.test(error.message)) {
            throw new ErrorUsuario("Ya existe un usuario con ese email.");
          }
          throw error;
        }
        const { error: errPerfil } = await admin.from("perfiles").insert({
          user_id: creado.user.id, email, nombre, roles, activo: true, debe_cambiar_clave: true,
        });
        if (errPerfil) {
          await admin.auth.admin.deleteUser(creado.user.id);
          throw errPerfil;
        }
        return respuesta({ ok: true });
      }

      case "actualizar": {
        const userId = String(body.user_id ?? "");
        const cambios: Record<string, unknown> = { updated_at: new Date().toISOString() };
        if (body.nombre !== undefined) cambios.nombre = validarNombre(body.nombre);
        if (body.roles !== undefined) cambios.roles = validarRoles(body.roles);
        if (body.activo !== undefined) cambios.activo = Boolean(body.activo);

        if (userId === yo.id) {
          if (cambios.activo === false) throw new ErrorUsuario("No podés desactivar tu propio usuario.");
          if (cambios.roles && !(cambios.roles as string[]).includes("administrador")) {
            throw new ErrorUsuario("No podés quitarte el rol de administrador.");
          }
        }

        const { data: actualizado, error } = await admin
          .from("perfiles").update(cambios).eq("user_id", userId).select("user_id").maybeSingle();
        if (error) throw error;
        if (!actualizado) throw new ErrorUsuario("Usuario no encontrado.");

        if (cambios.activo !== undefined) {
          const { error: errBan } = await admin.auth.admin.updateUserById(userId, {
            ban_duration: cambios.activo ? "none" : BLOQUEO,
          });
          if (errBan) throw errBan;
        }
        return respuesta({ ok: true });
      }

      case "resetear_clave": {
        const userId = String(body.user_id ?? "");
        const clave = validarClave(body.clave);
        const { error } = await admin.auth.admin.updateUserById(userId, { password: clave });
        if (error) throw error;
        await admin.from("perfiles")
          .update({ debe_cambiar_clave: userId !== yo.id, updated_at: new Date().toISOString() })
          .eq("user_id", userId);
        return respuesta({ ok: true });
      }

      default:
        return respuesta({ error: "Acción desconocida" }, 400);
    }
  } catch (e) {
    if (e instanceof ErrorUsuario) return respuesta({ error: e.message }, 400);
    console.error(e);
    return respuesta({ error: "No se pudo completar la operación." }, 500);
  }
});
