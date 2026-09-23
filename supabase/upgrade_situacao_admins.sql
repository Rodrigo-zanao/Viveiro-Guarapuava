-- Viveiro Guarapuava
-- Fluxo de situação dos orçamentos + administradores
-- Execute no SQL Editor do Supabase.

-- ============================================================
-- 1) ADMINISTRADORES
-- Tabela simples, somente com o nome do usuário.
-- Ex.: tonho@viveiro.local -> usuario = tonho
-- ============================================================

create table if not exists public.admins (
  usuario text primary key
);

insert into public.admins (usuario)
values
  ('tonho'),
  ('tono')
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
  or lower(usuario)=public.usuario_atual()
);

-- ============================================================
-- 2) SITUAÇÕES
-- ============================================================

update public.orcamentos
set status='ABERTO'
where status is null
   or status not in (
     'ABERTO',
     'AGUARDANDO_APROVACAO',
     'APROVADO',
     'CONCLUIDO'
   );

alter table public.orcamentos
  alter column status set default 'ABERTO';

alter table public.orcamentos
  alter column status set not null;

alter table public.orcamentos
  drop constraint if exists orcamentos_status_check;

alter table public.orcamentos
  add constraint orcamentos_status_check
  check (
    status in (
      'ABERTO',
      'AGUARDANDO_APROVACAO',
      'APROVADO',
      'CONCLUIDO'
    )
  );

-- Regras no próprio banco:
-- 1. orçamento novo sempre inicia ABERTO
-- 2. somente admin muda situação
-- 3. só pode avançar/voltar um passo
-- 4. dados do orçamento só podem ser alterados enquanto estiver ABERTO
create or replace function public.validar_fluxo_orcamento()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  pos_antiga integer;
  pos_nova integer;
begin
  if tg_op = 'INSERT' then
    if new.status <> 'ABERTO' then
      raise exception 'Todo orçamento novo deve iniciar em Aberto.';
    end if;

    return new;
  end if;

  if tg_op = 'UPDATE' then

    if old.status <> 'ABERTO'
       and (
            new.numero          is distinct from old.numero
         or new.cliente_id      is distinct from old.cliente_id
         or new.data_orcamento  is distinct from old.data_orcamento
         or new.validade        is distinct from old.validade
         or new.condicoes       is distinct from old.condicoes
         or new.desconto        is distinct from old.desconto
         or new.observacoes     is distinct from old.observacoes
         or new.cliente_dados   is distinct from old.cliente_dados
       )
    then
      raise exception 'Somente orçamentos em Aberto podem ser alterados.';
    end if;

    if new.status is distinct from old.status then

      -- Qualquer usuário autenticado pode enviar um orçamento ABERTO
      -- para AGUARDANDO_APROVACAO.
      -- Todas as demais mudanças (aprovar, concluir e voltar)
      -- são exclusivas dos administradores.
      if not (
        old.status = 'ABERTO'
        and new.status = 'AGUARDANDO_APROVACAO'
      ) and not public.eh_admin() then
        raise exception 'Somente administradores podem aprovar, concluir ou voltar a situação.';
      end if;

      pos_antiga := case old.status
        when 'ABERTO' then 1
        when 'AGUARDANDO_APROVACAO' then 2
        when 'APROVADO' then 3
        when 'CONCLUIDO' then 4
        else 0
      end;

      pos_nova := case new.status
        when 'ABERTO' then 1
        when 'AGUARDANDO_APROVACAO' then 2
        when 'APROVADO' then 3
        when 'CONCLUIDO' then 4
        else 0
      end;

      if pos_antiga = 0
         or pos_nova = 0
         or abs(pos_nova-pos_antiga) <> 1
      then
        raise exception
          'A situação deve seguir a sequência Aberto -> Aguardando Aprovação -> Aprovado -> Concluído, um passo por vez.';
      end if;

    end if;

    return new;
  end if;

  return new;
end;
$$;

drop trigger if exists trg_validar_fluxo_orcamento
on public.orcamentos;

create trigger trg_validar_fluxo_orcamento
before insert or update
on public.orcamentos
for each row
execute function public.validar_fluxo_orcamento();

-- Fora de Aberto não pode excluir.
create or replace function public.validar_exclusao_orcamento()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if old.status <> 'ABERTO' then
    raise exception 'Somente orçamentos em Aberto podem ser excluídos.';
  end if;

  return old;
end;
$$;

drop trigger if exists trg_validar_exclusao_orcamento
on public.orcamentos;

create trigger trg_validar_exclusao_orcamento
before delete
on public.orcamentos
for each row
execute function public.validar_exclusao_orcamento();

-- ============================================================
-- 3) ITENS DO ORÇAMENTO
-- Também ficam travados quando o orçamento sair de ABERTO.
-- ============================================================

-- Remove políticas antigas da tabela de itens. Isso é importante porque
-- políticas RLS permissivas são combinadas com OR; uma política antiga using(true)
-- poderia liberar edição de itens de um orçamento já aprovado.
do $
declare
  p record;
begin
  for p in
    select policyname
    from pg_policies
    where schemaname='public'
      and tablename='orcamento_itens'
  loop
    execute format('drop policy if exists %I on public.orcamento_itens',p.policyname);
  end loop;
end
$;

create policy "consultar itens"
on public.orcamento_itens
for select
to authenticated
using (true);

create policy "criar itens"
on public.orcamento_itens
for insert
to authenticated
with check (
  exists (
    select 1
    from public.orcamentos o
    where o.id=orcamento_id
      and o.status='ABERTO'
  )
);

create policy "alterar itens"
on public.orcamento_itens
for update
to authenticated
using (
  exists (
    select 1
    from public.orcamentos o
    where o.id=orcamento_id
      and o.status='ABERTO'
  )
)
with check (
  exists (
    select 1
    from public.orcamentos o
    where o.id=orcamento_id
      and o.status='ABERTO'
  )
);

create policy "excluir itens"
on public.orcamento_itens
for delete
to authenticated
using (
  exists (
    select 1
    from public.orcamentos o
    where o.id=orcamento_id
      and o.status='ABERTO'
  )
);

-- ============================================================
-- 4) HISTÓRICO AUTOMÁTICO DAS MUDANÇAS DE SITUAÇÃO
-- ============================================================

create or replace function public.registrar_mudanca_situacao()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  acao_txt text;
begin
  if new.status is distinct from old.status then

    acao_txt := case
      when old.status='ABERTO'
       and new.status='AGUARDANDO_APROVACAO'
        then 'ENVIADO PARA APROVAÇÃO'

      when old.status='AGUARDANDO_APROVACAO'
       and new.status='ABERTO'
        then 'RETORNADO PARA ABERTO'

      when old.status='AGUARDANDO_APROVACAO'
       and new.status='APROVADO'
        then 'APROVADO'

      when old.status='APROVADO'
       and new.status='AGUARDANDO_APROVACAO'
        then 'APROVAÇÃO ESTORNADA'

      when old.status='APROVADO'
       and new.status='CONCLUIDO'
        then 'CONCLUÍDO'

      when old.status='CONCLUIDO'
       and new.status='APROVADO'
        then 'CONCLUSÃO ESTORNADA'

      else 'SITUAÇÃO ALTERADA'
    end;

    insert into public.orcamento_historico (
      orcamento_id,
      acao,
      usuario_id,
      usuario_email,
      detalhes
    )
    values (
      new.id,
      acao_txt,
      auth.uid(),
      auth.jwt()->>'email',
      jsonb_build_object(
        'de',old.status,
        'para',new.status
      )
    );

  end if;

  return new;
end;
$$;

drop trigger if exists trg_historico_situacao
on public.orcamentos;

create trigger trg_historico_situacao
after update of status
on public.orcamentos
for each row
execute function public.registrar_mudanca_situacao();

-- ============================================================
-- 5) VIEW DA LISTA DE ORÇAMENTOS COM SITUAÇÃO
-- ============================================================

drop view if exists public.vw_orcamentos_totais;

create view public.vw_orcamentos_totais
with (security_invoker = true)
as
select
  o.id,
  o.numero,
  c.cliente,
  o.data_orcamento,
  coalesce(sum(oi.subtotal),0)::numeric(14,2) as subtotal,
  o.desconto,
  greatest(
    coalesce(sum(oi.subtotal),0)-coalesce(o.desconto,0),
    0
  )::numeric(14,2) as total,
  o.alterado_em,
  o.status
from public.orcamentos o
left join public.clientes c
  on c.id=o.cliente_id
left join public.orcamento_itens oi
  on oi.orcamento_id=o.id
group by
  o.id,
  o.numero,
  c.cliente,
  o.data_orcamento,
  o.desconto,
  o.alterado_em,
  o.status;

grant select on public.vw_orcamentos_totais
to authenticated;

-- FIM
