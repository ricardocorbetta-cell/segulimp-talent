-- Parte 1 (no rompe nada): lista del equipo con acceso al panel y función del test situacional.
-- La tabla equipo y es_equipo() fueron reemplazadas por perfiles y roles en la 003.

create table if not exists public.equipo (
  email text primary key check (email = lower(email)),
  nombre text,
  created_at timestamptz not null default now()
);
alter table public.equipo enable row level security;
-- Sin políticas: la tabla solo se consulta desde es_equipo() y se carga desde el dashboard de Supabase.

create or replace function public.es_equipo()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.equipo e
    where e.email = lower(coalesce(auth.jwt() ->> 'email', ''))
  );
$$;

revoke all on function public.es_equipo() from public;
grant execute on function public.es_equipo() to anon, authenticated;

-- El test es público: guarda solo el resultado del test en el candidato con ese nombre,
-- una sola vez y nunca sobre candidatos cerrados.
create or replace function public.registrar_test(
  p_nombre text,
  p_puntaje integer,
  p_tier text,
  p_detalle text
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id bigint;
begin
  if p_puntaje is null or p_puntaje < 0 or p_puntaje > 18 then
    raise exception 'Puntaje inválido';
  end if;
  if p_tier not in ('Avanza a entrevista', 'Evaluar con cautela', 'No avanza') then
    raise exception 'Resultado inválido';
  end if;

  select c.id into v_id
  from public.candidatos c
  where lower(trim(c.nombre)) = lower(trim(p_nombre))
    and c.puntaje_test is null
    and coalesce(c.etapa, '') not in ('Contratado', 'Descartado')
  order by c.created_at desc
  limit 1;

  if v_id is null then
    return false;
  end if;

  update public.candidatos
  set puntaje_test = p_puntaje,
      tier_test = p_tier,
      detalle_test = left(p_detalle, 1000),
      etapa = 'Test completado'
  where id = v_id;

  return true;
end;
$$;

revoke all on function public.registrar_test(text, integer, text, text) from public;
grant execute on function public.registrar_test(text, integer, text, text) to anon, authenticated;
