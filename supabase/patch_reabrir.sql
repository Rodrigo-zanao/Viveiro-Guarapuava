-- Viveiro Guarapuava
-- Patch: permitir REABRIR orçamento diretamente para ABERTO por administrador.
-- Execute no SQL Editor do Supabase.

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
    if old.status <> 'ABERTO' and (
         new.numero          is distinct from old.numero
      or new.cliente_id      is distinct from old.cliente_id
      or new.data_orcamento  is distinct from old.data_orcamento
      or new.validade        is distinct from old.validade
      or new.condicoes       is distinct from old.condicoes
      or new.desconto        is distinct from old.desconto
      or new.observacoes     is distinct from old.observacoes
      or new.cliente_dados   is distinct from old.cliente_dados
    ) then
      raise exception 'Somente orçamentos em Aberto podem ser alterados.';
    end if;

    if new.status is distinct from old.status then
      -- Usuário comum só pode fazer ABERTO -> AGUARDANDO_APROVACAO.
      -- Todas as demais mudanças, inclusive REABRIR, exigem admin.
      if not (
        old.status='ABERTO'
        and new.status='AGUARDANDO_APROVACAO'
      ) and not public.eh_admin() then
        raise exception 'Somente administradores podem aprovar, concluir ou reabrir o orçamento.';
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

      -- Admin pode reabrir direto de qualquer situação para ABERTO.
      if not (
           public.eh_admin()
       and new.status='ABERTO'
       and old.status<>'ABERTO'
      ) and (
           pos_antiga=0
        or pos_nova=0
        or abs(pos_nova-pos_antiga)<>1
      ) then
        raise exception 'A situação deve avançar ou voltar uma etapa por vez.';
      end if;
    end if;

    return new;
  end if;

  return new;
end;
$$;

drop trigger if exists trg_validar_fluxo_orcamento on public.orcamentos;

create trigger trg_validar_fluxo_orcamento
before insert or update
on public.orcamentos
for each row
execute function public.validar_fluxo_orcamento();


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
      when new.status='ABERTO' and old.status<>'ABERTO'
        then 'REABERTO'
      when old.status='ABERTO' and new.status='AGUARDANDO_APROVACAO'
        then 'ENVIADO PARA APROVAÇÃO'
      when old.status='AGUARDANDO_APROVACAO' and new.status='APROVADO'
        then 'APROVADO'
      when old.status='APROVADO' and new.status='AGUARDANDO_APROVACAO'
        then 'APROVAÇÃO ESTORNADA'
      when old.status='APROVADO' and new.status='CONCLUIDO'
        then 'CONCLUÍDO'
      when old.status='CONCLUIDO' and new.status='APROVADO'
        then 'CONCLUSÃO ESTORNADA'
      else 'SITUAÇÃO ALTERADA'
    end;

    insert into public.orcamento_historico
      (orcamento_id,acao,usuario_id,usuario_email,detalhes)
    values
      (
        new.id,
        acao_txt,
        auth.uid(),
        auth.jwt()->>'email',
        jsonb_build_object('de',old.status,'para',new.status)
      );
  end if;

  return new;
end;
$$;

drop trigger if exists trg_historico_situacao on public.orcamentos;

create trigger trg_historico_situacao
after update of status
on public.orcamentos
for each row
execute function public.registrar_mudanca_situacao();
