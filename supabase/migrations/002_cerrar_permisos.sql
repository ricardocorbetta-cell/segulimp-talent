-- Parte 2: cierra el acceso público. Aplicar DESPUÉS de publicar el dashboard con login
-- y de cargar al menos un email en public.equipo.

-- ===== candidatos =====
drop policy if exists "Acceso total anon a candidatos" on public.candidatos;
drop policy if exists "Actualización anon de candidatos" on public.candidatos;
drop policy if exists "Cualquiera puede postularse" on public.candidatos;

-- El formulario público solo puede crear postulaciones nuevas, sin evaluación ni notas
create policy "Cualquiera puede postularse" on public.candidatos
  for insert to anon, authenticated
  with check (
    etapa = 'CV recibido'
    and puntaje_cv is null and tier_cv is null and motivo_cv is null
    and puntaje_test is null and tier_test is null and detalle_test is null
    and fecha_entrevista is null and notas is null
  );

create policy "Equipo ve candidatos" on public.candidatos
  for select to authenticated using (public.es_equipo());
create policy "Equipo edita candidatos" on public.candidatos
  for update to authenticated using (public.es_equipo()) with check (public.es_equipo());
create policy "Equipo borra candidatos" on public.candidatos
  for delete to authenticated using (public.es_equipo());

-- ===== puestos =====
drop policy if exists "Acceso total anon a puestos" on public.puestos;
-- "Lectura pública de puestos activos" se mantiene para el formulario

create policy "Equipo gestiona puestos" on public.puestos
  for all to authenticated using (public.es_equipo()) with check (public.es_equipo());

-- ===== CVs (storage) =====
update storage.buckets
set public = false,
    file_size_limit = 10485760,
    allowed_mime_types = array[
      'application/pdf',
      'application/msword',
      'application/vnd.openxmlformats-officedocument.wordprocessingml.document'
    ]
where id = 'cvs';

drop policy if exists "Lectura pública de CVs" on storage.objects;
create policy "Equipo ve CVs" on storage.objects
  for select to authenticated using (bucket_id = 'cvs' and public.es_equipo());
-- "Cualquiera puede subir su CV" (insert) se mantiene para el formulario
