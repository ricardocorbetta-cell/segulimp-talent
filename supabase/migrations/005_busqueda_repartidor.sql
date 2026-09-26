-- Búsqueda Repartidor (Vendedor Comercial queda cerrada) y respuestas a requisitos del formulario.

insert into public.puestos (nombre, activo)
select 'Repartidor', true
where not exists (select 1 from public.puestos where nombre = 'Repartidor');

update public.puestos set activo = false where nombre = 'Vendedor Comercial';

-- { "Pregunta": "Respuesta", ... } tal como la contestó el candidato
alter table public.candidatos
  add column if not exists requisitos jsonb
  check (requisitos is null or (jsonb_typeof(requisitos) = 'object' and pg_column_size(requisitos) < 4000));
