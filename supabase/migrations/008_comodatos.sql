-- 008 · Comodatos: equipos entregados en comodato a cada cliente.
-- Los usa Seguimiento Comercial (equipos por cliente, contra lo que compra)
-- y Alerta Segulimp (equipos sin ubicar en el cliente; al activar un sticker se elige cuál es).
-- Aplicada en producción el 16/10/2026 desde el panel de Supabase. Carga inicial: planilla "Comodatos BASE DE DATOS"
-- (1.001 entregas, 4.390 equipos, 61 códigos); se crearon en Alerta Segulimp los 180 clientes con comodato que están en la cartera.

create table if not exists public.comodatos_codigos (
  codigo text primary key,
  linea text not null,
  descripcion text,
  actualizado_en timestamptz not null default now()
);

create table if not exists public.comodatos (
  id bigserial primary key,
  cliente_id bigint references public.comercial_clientes(id) on delete set null,
  cliente_planilla text not null,             -- el nombre tal como figura en la planilla
  codigo text not null references public.comodatos_codigos(codigo) on update cascade,
  cantidad integer not null check (cantidad > 0),
  fecha date,
  vendedor_planilla text,
  nota text,
  origen text,                                 -- hoja y fila de la planilla
  retirados integer not null default 0,
  retiro_nota text,
  retiro_en timestamptz,
  retiro_por uuid,
  creado_en timestamptz not null default now(),
  constraint comodatos_retirados_ok check (retirados between 0 and cantidad)
);
create index if not exists comodatos_cliente_idx on public.comodatos (cliente_id);
create index if not exists comodatos_planilla_idx on public.comodatos (cliente_planilla);

alter table public.alertas_sitios add column if not exists cliente_id bigint references public.comercial_clientes(id) on delete set null;
alter table public.alertas_equipos add column if not exists comodato_id bigint references public.comodatos(id) on delete set null;
create index if not exists alertas_sitios_cliente_idx on public.alertas_sitios (cliente_id);
create index if not exists alertas_equipos_comodato_idx on public.alertas_equipos (comodato_id);

-- Ve comodatos: quien ve todo en comercial, el vendedor de ese cliente, o un usuario de Alerta Segulimp.
alter table public.comodatos enable row level security;
alter table public.comodatos_codigos enable row level security;
drop policy if exists comodatos_select on public.comodatos;
create policy comodatos_select on public.comodatos for select to authenticated
  using ((select public.comercial_ve_todo()) or (select public.alertas_mi_distribuidora()) is not null
         or cliente_id in (select c.id from public.comercial_clientes c where c.vendedor_id in (select public.comercial_mis_vendedores())));
drop policy if exists comodatos_admin on public.comodatos;
create policy comodatos_admin on public.comodatos for all to authenticated
  using ((select public.comercial_es_admin())) with check ((select public.comercial_es_admin()));
drop policy if exists comodatos_codigos_select on public.comodatos_codigos;
create policy comodatos_codigos_select on public.comodatos_codigos for select to authenticated using (true);
drop policy if exists comodatos_codigos_admin on public.comodatos_codigos;
create policy comodatos_codigos_admin on public.comodatos_codigos for all to authenticated
  using ((select public.comercial_es_admin()) or (select public.alertas_puede_editar()))
  with check ((select public.comercial_es_admin()) or (select public.alertas_puede_editar()));
grant select on public.comodatos, public.comodatos_codigos to authenticated;
grant insert, update, delete on public.comodatos, public.comodatos_codigos to authenticated;
grant usage on sequence public.comodatos_id_seq to authenticated;

-- Equipos ubicados con sticker, por entrega
create or replace view public.comodatos_estado with (security_invoker = on) as
select c.id, c.cliente_id, c.cliente_planilla, c.codigo, k.linea, k.descripcion, c.cantidad, c.retirados, c.fecha,
       c.vendedor_planilla, c.nota, c.origen, c.retiro_nota, c.retiro_en,
       coalesce(u.ubicados, 0)::int as ubicados,
       greatest(c.cantidad - c.retirados - coalesce(u.ubicados, 0), 0)::int as sin_ubicar
  from public.comodatos c
  join public.comodatos_codigos k on k.codigo = c.codigo
  left join lateral (select count(*) as ubicados from public.alertas_equipos e
                      where e.comodato_id = c.id and e.activo) u on true;
grant select on public.comodatos_estado to authenticated;

-- Por cliente: equipos instalados contra lo que compra
create or replace view public.comodatos_clientes with (security_invoker = on) as
select c.cliente_id,
       sum(c.cantidad - c.retirados)::int as equipos,
       sum(c.retirados)::int as retirados,
       count(distinct c.codigo)::int as codigos,
       min(c.fecha) as primera_entrega,
       max(c.fecha) as ultima_entrega,
       (select coalesce(sum(v.importe), 0) from public.comercial_ventas_cliente v
         where v.cliente_id = c.cliente_id and v.fecha > current_date - 365) as ventas_12m,
       (select coalesce(sum(v.importe), 0) from public.comercial_ventas_cliente v
         where v.cliente_id = c.cliente_id and v.fecha > current_date - 91) as ventas_3m,
       (select max(v.fecha) from public.comercial_ventas_cliente v
         where v.cliente_id = c.cliente_id and v.importe > 0) as ultima_compra
  from public.comodatos c
 where c.cliente_id is not null
 group by c.cliente_id;
grant select on public.comodatos_clientes to authenticated;

-- Informar equipos retirados: administrador comercial, mantenimiento/administrador de Alerta, o el vendedor del cliente.
create or replace function public.comodatos_retirar(p_id bigint, p_cantidad integer, p_nota text default null)
returns integer language plpgsql security definer set search_path to '' as $$
declare
  v public.comodatos;
  v_ubic int;
begin
  select * into v from public.comodatos where id = p_id for update;
  if not found then raise exception 'No existe ese comodato' using errcode = 'P0002'; end if;
  if not (public.comercial_es_admin()
          or (public.alertas_mi_distribuidora() is not null and public.alertas_puede_gestionar())
          or exists (select 1 from public.comercial_clientes c
                      where c.id = v.cliente_id and c.vendedor_id in (select public.comercial_mis_vendedores()))) then
    raise exception 'No tenés permiso para informar retiros' using errcode = '42501';
  end if;
  if p_cantidad is null or p_cantidad < 0 or p_cantidad > v.cantidad then
    raise exception 'La cantidad retirada tiene que estar entre 0 y %', v.cantidad using errcode = '22023';
  end if;
  select count(*) into v_ubic from public.alertas_equipos e where e.comodato_id = p_id and e.activo;
  if p_cantidad > v.cantidad - v_ubic then
    raise exception 'Hay % equipos de esta entrega con sticker activo: desactivalos primero en Alerta Segulimp', v_ubic using errcode = '22023';
  end if;
  update public.comodatos
     set retirados = p_cantidad,
         retiro_nota = nullif(trim(coalesce(p_nota, '')), ''),
         retiro_en = case when p_cantidad > 0 then now() end,
         retiro_por = case when p_cantidad > 0 then auth.uid() end
   where id = p_id;
  return p_cantidad;
end;
$$;
revoke execute on function public.comodatos_retirar(bigint, integer, text) from public, anon;
grant execute on function public.comodatos_retirar(bigint, integer, text) to authenticated;

-- Vincular nombres de la planilla con un cliente de la cartera
create or replace function public.comodatos_vincular(p_planilla text, p_cliente bigint)
returns integer language plpgsql security definer set search_path to '' as $$
declare n int;
begin
  if not public.comercial_es_admin() then raise exception 'Solo un administrador puede vincular' using errcode = '42501'; end if;
  if p_cliente is not null and not exists (select 1 from public.comercial_clientes where id = p_cliente) then
    raise exception 'Cliente no encontrado' using errcode = 'P0002';
  end if;
  update public.comodatos set cliente_id = p_cliente where cliente_planilla = p_planilla;
  get diagnostics n = row_count;
  return n;
end;
$$;
revoke execute on function public.comodatos_vincular(text, bigint) from public, anon;
grant execute on function public.comodatos_vincular(text, bigint) to authenticated;

-- Activar sticker: opcionalmente sobre un equipo de comodato (reemplaza la versión de 007)
drop function if exists public.alertas_activar_sticker(text, uuid, uuid, text, uuid, uuid, text);
create or replace function public.alertas_activar_sticker(p_codigo text, p_sitio_id uuid, p_sector_id uuid, p_sector_nuevo text,
  p_tipo_id uuid, p_producto_id uuid, p_ubicacion text, p_comodato_id bigint default null)
returns uuid language plpgsql security definer set search_path to '' as $function$
declare
  v_dist uuid := public.alertas_mi_distribuidora();
  v_codigo text := upper(trim(coalesce(p_codigo, '')));
  v_sticker public.alertas_stickers;
  v_sector uuid;
  v_nombre text := trim(coalesce(p_sector_nuevo, ''));
  v_ubicacion text := trim(coalesce(p_ubicacion, ''));
  v_equipo uuid;
  v_cliente bigint;
  v_libres int;
begin
  if v_dist is null or not public.alertas_puede_gestionar() then
    raise exception 'No tenés permiso para activar stickers' using errcode = '42501';
  end if;
  select * into v_sticker from public.alertas_stickers st
   where st.codigo = v_codigo and st.distribuidora_id = v_dist for update;
  if not found then
    raise exception 'No existe un sticker con el código %', v_codigo using errcode = 'P0002';
  end if;
  if v_sticker.equipo_id is not null then
    raise exception 'Este sticker ya está activado' using errcode = '23505';
  end if;
  select s.cliente_id into v_cliente from public.alertas_sitios s where s.id = p_sitio_id and s.distribuidora_id = v_dist;
  if not found then
    raise exception 'Cliente no encontrado' using errcode = 'P0002';
  end if;
  if v_ubicacion = '' then
    raise exception 'Falta la ubicación' using errcode = '22023';
  end if;
  if not exists (select 1 from public.alertas_tipos t where t.id = p_tipo_id and t.distribuidora_id = v_dist and t.activo) then
    raise exception 'Elegí el tipo de objeto' using errcode = '22023';
  end if;
  if p_comodato_id is not null then
    select c.cantidad - c.retirados - (select count(*) from public.alertas_equipos e where e.comodato_id = c.id and e.activo)
      into v_libres
      from public.comodatos c where c.id = p_comodato_id and c.cliente_id = v_cliente;
    if not found then
      raise exception 'Ese equipo de comodato no es de este cliente' using errcode = '22023';
    end if;
    if v_libres <= 0 then
      raise exception 'Todos los equipos de esa entrega ya tienen sticker' using errcode = '22023';
    end if;
  end if;
  if p_sector_id is not null then
    select se.id into v_sector from public.alertas_sectores se where se.id = p_sector_id and se.sitio_id = p_sitio_id;
  elsif v_nombre <> '' then
    select se.id into v_sector from public.alertas_sectores se
     where se.sitio_id = p_sitio_id and lower(se.nombre) = lower(v_nombre);
    if v_sector is null then
      insert into public.alertas_sectores (sitio_id, nombre, orden)
      values (p_sitio_id, left(v_nombre, 80), (select count(*) from public.alertas_sectores x where x.sitio_id = p_sitio_id))
      returning id into v_sector;
    end if;
  end if;
  if v_sector is null then
    raise exception 'Elegí el sector' using errcode = '22023';
  end if;
  insert into public.alertas_equipos (sitio_id, sector_id, tipo_id, producto_id, ubicacion, codigo, comodato_id)
  values (p_sitio_id, v_sector, p_tipo_id, p_producto_id, left(v_ubicacion, 200), v_codigo, p_comodato_id)
  returning id into v_equipo;
  update public.alertas_stickers
     set equipo_id = v_equipo, activado_en = now(), activado_por = auth.uid()
   where codigo = v_codigo;
  return v_equipo;
end;
$function$;
revoke execute on function public.alertas_activar_sticker(text, uuid, uuid, text, uuid, uuid, text, bigint) from public, anon;
grant execute on function public.alertas_activar_sticker(text, uuid, uuid, text, uuid, uuid, text, bigint) to authenticated;
