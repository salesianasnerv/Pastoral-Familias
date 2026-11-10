-- Buenos días para familias · contador de visitas (10-11-2026). PEDIR VISTO BUENO A MARIÁN ANTES.
-- Ejecutar en Supabase → SQL Editor, proyecto «Acceso Microsoft 365». Se puede volver a ejecutar.
--
-- Qué hace:
--   · La web de familias (sin inicio de sesión) suma 1 cada vez que alguien entra o pulsa algo.
--   · Solo se guarda: día, qué se ha pulsado, etapa y si viene de una prueba. Nada más:
--     ni quién es, ni IP, ni navegador, ni cookies. Son totales, no se puede saber quién ha entrado.
--   · Las cifras solo las puede leer el grupo «Pastoral» de Microsoft 365 (sincronizado cada noche),
--     desde la página /visitas con inicio de sesión.
--
-- Tablas y funciones nuevas (prefijo pas_):
--   pas_visitas            tabla de totales (dia, evento, etapa, prueba, total)
--   pas_contar(...)        la usa la web de familias para sumar 1 (cualquiera puede llamarla)
--   pas_visitas_ver(...)   la usa /visitas para leer las cifras (solo grupo Pastoral)
--   pas_es_pastoral()      dice si la persona que ha iniciado sesión está en el grupo Pastoral

begin;

create table if not exists pas_visitas (
  dia     date    not null,
  evento  text    not null,
  etapa   text    not null default '',
  prueba  boolean not null default false,
  total   integer not null default 0,
  primary key (dia, evento, etapa, prueba)
);

-- Nadie lee ni escribe la tabla directamente: solo a través de las funciones de abajo.
alter table pas_visitas enable row level security;
revoke all on table pas_visitas from public, anon, authenticated;

-- Sumar 1. Solo admite los eventos y etapas de la web; cualquier otro valor se ignora.
create or replace function pas_contar(p_evento text, p_etapa text default '', p_prueba boolean default false)
returns void language plpgsql security definer set search_path = public as $$
begin
  if p_evento not in ('entrada', 'etapa', 'recurso', 'video', 'lema', 'aqui_y_ahora') then return; end if;
  if coalesce(p_etapa, '') not in ('', 'Infantil', '1º-3º EPO', '4º-6º EPO', 'ESO y Bachillerato', 'CCFF') then return; end if;

  insert into pas_visitas as v (dia, evento, etapa, prueba, total)
  values ((now() at time zone 'Europe/Madrid')::date, p_evento, coalesce(p_etapa, ''), coalesce(p_prueba, false), 1)
  on conflict (dia, evento, etapa, prueba) do update set total = v.total + 1;
end $$;
revoke execute on function pas_contar(text, text, boolean) from public;
grant execute on function pas_contar(text, text, boolean) to anon, authenticated;

-- ¿Está en el grupo Pastoral?
create or replace function pas_es_pastoral() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from personal p
                 where p.email = email_actual() and p.activo and 'pastoral' = any(p.grupos_entra))
$$;
revoke execute on function pas_es_pastoral() from public, anon;
grant execute on function pas_es_pastoral() to authenticated;

-- Leer las cifras entre dos fechas (solo grupo Pastoral).
create or replace function pas_visitas_ver(p_desde date, p_hasta date, p_con_pruebas boolean default false)
returns table (dia date, evento text, etapa text, total integer)
language plpgsql stable security definer set search_path = public as $$
begin
  if not pas_es_pastoral() then
    raise exception 'Solo el grupo Pastoral puede ver las visitas';
  end if;
  return query
    select v.dia, v.evento, v.etapa, sum(v.total)::integer
    from pas_visitas v
    where v.dia between p_desde and p_hasta and (p_con_pruebas or not v.prueba)
    group by v.dia, v.evento, v.etapa
    order by v.dia, v.evento, v.etapa;
end $$;
revoke execute on function pas_visitas_ver(date, date, boolean) from public, anon;
grant execute on function pas_visitas_ver(date, date, boolean) to authenticated;

commit;

-- Comprobaciones
-- 1) Quién podrá ver las cifras (tienen que salir las personas de Pastoral):
select nombre, email from personal where activo and 'pastoral' = any(grupos_entra) order by nombre;
-- 2) Últimos totales guardados:
-- select * from pas_visitas order by dia desc, evento, etapa limit 50;

-- Para deshacerlo todo (solo si se decide quitar el contador):
-- drop function if exists pas_visitas_ver(date, date, boolean);
-- drop function if exists pas_es_pastoral();
-- drop function if exists pas_contar(text, text, boolean);
-- drop table if exists pas_visitas;
