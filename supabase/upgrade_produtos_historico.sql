-- Upgrade da versão Supabase do Viveiro Guarapuava
-- Cria produtos e histórico dos orçamentos.
-- Pode ser executado no SQL Editor do Supabase.

create extension if not exists pgcrypto;

create or replace function public.atualizar_data_alteracao()
returns trigger
language plpgsql
as $$
begin
  new.alterado_em = now();
  return new;
end;
$$;

-- ============================================================
-- PRODUTOS
-- ============================================================

create table if not exists public.produtos (
  id uuid primary key default gen_random_uuid(),
  descricao text not null,
  valor_unitario numeric(14,2) not null default 0,
  ativo boolean not null default true,
  criado_em timestamptz not null default now(),
  alterado_em timestamptz not null default now(),
  criado_por uuid default auth.uid() references auth.users(id)
);

create unique index if not exists idx_produtos_descricao_unica
on public.produtos ((lower(trim(descricao))));

create index if not exists idx_produtos_ativo
on public.produtos(ativo);

drop trigger if exists trg_produtos_alterado_em on public.produtos;

create trigger trg_produtos_alterado_em
before update on public.produtos
for each row
execute function public.atualizar_data_alteracao();

alter table public.produtos enable row level security;

grant select, insert, update, delete
on public.produtos
to authenticated;

drop policy if exists "consultar produtos" on public.produtos;
drop policy if exists "criar produtos" on public.produtos;
drop policy if exists "alterar produtos" on public.produtos;
drop policy if exists "excluir produtos" on public.produtos;

create policy "consultar produtos"
on public.produtos
for select
to authenticated
using (true);

create policy "criar produtos"
on public.produtos
for insert
to authenticated
with check (true);

create policy "alterar produtos"
on public.produtos
for update
to authenticated
using (true)
with check (true);

create policy "excluir produtos"
on public.produtos
for delete
to authenticated
using (true);

-- ============================================================
-- HISTÓRICO DOS ORÇAMENTOS
-- ============================================================

create table if not exists public.orcamento_historico (
  id uuid primary key default gen_random_uuid(),
  orcamento_id uuid not null
    references public.orcamentos(id)
    on delete cascade,
  acao text not null,
  usuario_id uuid default auth.uid()
    references auth.users(id),
  usuario_email text,
  ocorrido_em timestamptz not null default now(),
  detalhes jsonb not null default '{}'::jsonb
);

create index if not exists idx_orcamento_historico_orcamento
on public.orcamento_historico(orcamento_id, ocorrido_em desc);

alter table public.orcamento_historico enable row level security;

grant select, insert
on public.orcamento_historico
to authenticated;

drop policy if exists "consultar historico" on public.orcamento_historico;
drop policy if exists "criar historico" on public.orcamento_historico;

create policy "consultar historico"
on public.orcamento_historico
for select
to authenticated
using (true);

create policy "criar historico"
on public.orcamento_historico
for insert
to authenticated
with check (true);

-- Fim do upgrade.
