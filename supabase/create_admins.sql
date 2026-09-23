-- Viveiro Guarapuava
-- Criação/ajuste da tabela de administradores
-- Pode ser executado mais de uma vez.

create table if not exists public.admins (
  usuario text primary key
);

insert into public.admins (usuario)
values ('tonho')
on conflict (usuario) do nothing;

alter table public.admins enable row level security;

grant select on public.admins to authenticated;

create or replace function public.usuario_atual()
returns text
language sql
stable
security definer
set search_path = public
as $$
  select lower(split_part(coalesce(auth.jwt()->>'email',''),'@',1));
$$;

create or replace function public.eh_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.admins a
    where lower(a.usuario) = public.usuario_atual()
  );
$$;

revoke all on function public.usuario_atual() from public;
revoke all on function public.eh_admin() from public;

grant execute on function public.usuario_atual() to authenticated;
grant execute on function public.eh_admin() to authenticated;

drop policy if exists "ver admins" on public.admins;

create policy "ver admins"
on public.admins
for select
to authenticated
using (
  public.eh_admin()
  or lower(usuario) = public.usuario_atual()
);

select * from public.admins order by usuario;
