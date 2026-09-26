-- Usuarios del HUB con roles. Reemplaza la tabla equipo (quedó vacía) por perfiles.
-- Los usuarios se crean desde la pantalla Usuarios del HUB (función admin-usuarios).

create table if not exists public.perfiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  email text not null unique check (email = lower(email)),
  nombre text not null,
  roles text[] not null default '{}'
    check (roles <@ array['administrador','rrhh','comercial','mantenimiento','consulta']::text[]),
  activo boolean not null default true,
  debe_cambiar_clave boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.perfiles enable row level security;

drop policy if exists "Cada uno ve su perfil" on public.perfiles;
create policy "Cada uno ve su perfil" on public.perfiles
  for select to authenticated using (user_id = auth.uid());
-- Altas, cambios y bajas solo por la función admin-usuarios (service role).

create or replace function public.mis_roles()
returns text[]
language sql stable security definer set search_path = ''
as $$
  select coalesce(
    (select p.roles from public.perfiles p where p.user_id = auth.uid() and p.activo),
    '{}'::text[]
  );
$$;

create or replace function public.tiene_rol(p_roles text[])
returns boolean
language sql stable security definer set search_path = ''
as $$
  select public.mis_roles() && p_roles;
$$;

-- Ver el panel de talento
create or replace function public.es_equipo()
returns boolean
language sql stable security definer set search_path = ''
as $$
  select public.tiene_rol(array['administrador','rrhh','consulta']);
$$;

-- Modificar candidatos y puestos
create or replace function public.puede_editar_talento()
returns boolean
language sql stable security definer set search_path = ''
as $$
  select public.tiene_rol(array['administrador','rrhh']);
$$;

create or replace function public.clave_cambiada()
returns void
language sql security definer set search_path = ''
as $$
  update public.perfiles set debe_cambiar_clave = false, updated_at = now()
  where user_id = auth.uid();
$$;

revoke all on function public.mis_roles() from public;
revoke all on function public.tiene_rol(text[]) from public;
revoke all on function public.puede_editar_talento() from public;
revoke all on function public.clave_cambiada() from public;
grant execute on function public.mis_roles() to anon, authenticated;
grant execute on function public.tiene_rol(text[]) to anon, authenticated;
grant execute on function public.puede_editar_talento() to anon, authenticated;
grant execute on function public.clave_cambiada() to authenticated;

drop table if exists public.equipo;
