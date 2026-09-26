-- Qué test situacional se le envió / completó cada candidato (vendedor, repartidor, ...).

alter table public.candidatos add column if not exists test_tipo text;

-- El formulario público no puede cargar test_tipo
drop policy if exists "Cualquiera puede postularse" on public.candidatos;
create policy "Cualquiera puede postularse" on public.candidatos
  for insert to anon, authenticated
  with check (
    etapa = 'CV recibido'
    and puntaje_cv is null and tier_cv is null and motivo_cv is null
    and puntaje_test is null and tier_test is null and detalle_test is null
    and fecha_entrevista is null and notas is null and test_tipo is null
  );

-- registrar_test ahora recibe el tipo de test que se completó
drop function if exists public.registrar_test(text, integer, text, text);

create or replace function public.registrar_test(
  p_nombre text,
  p_puntaje integer,
  p_tier text,
  p_detalle text,
  p_tipo text default null
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
  if p_tipo is not null and p_tipo !~ '^[a-z]{1,30}$' then
    raise exception 'Tipo de test inválido';
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
      test_tipo = coalesce(p_tipo, test_tipo),
      etapa = 'Test completado'
  where id = v_id;

  return true;
end;
$$;

revoke all on function public.registrar_test(text, integer, text, text, text) from public;
grant execute on function public.registrar_test(text, integer, text, text, text) to anon, authenticated;
