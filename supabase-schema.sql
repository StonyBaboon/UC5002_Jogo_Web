-- NEUROQUIZ | Executar no SQL Editor do projeto Supabase.
-- Guarda nomes e respostas completas apenas no servidor.

create table if not exists public.neuroquiz_participants (
  id uuid primary key default gen_random_uuid(),
  full_name text not null check (char_length(trim(full_name)) between 1 and 80),
  score integer not null default 0 check (score >= 0),
  total integer not null default 0 check (total >= 0),
  answers jsonb not null default '[]'::jsonb,
  access_token uuid not null default gen_random_uuid(),
  completed_at timestamptz not null default now()
);

create table if not exists public.neuroquiz_admins (
  user_id uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);

alter table public.neuroquiz_participants enable row level security;
alter table public.neuroquiz_admins enable row level security;
revoke all on public.neuroquiz_participants from anon, authenticated;
revoke all on public.neuroquiz_admins from anon, authenticated;

-- O nome verdadeiro não é devolvido por esta função.
-- Apenas participantes que terminaram e possuem o token devolvido no envio
-- podem abrir os resultados públicos.
create or replace function public.submit_neuroquiz_participation(
  p_name text,
  p_score integer,
  p_total integer,
  p_answers jsonb
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
  v_token uuid;
begin
  if p_name is null or char_length(trim(p_name)) < 1 or char_length(trim(p_name)) > 80 then
    raise exception 'Nome inválido.';
  end if;
  if p_score is null or p_total is null or p_score < 0 or p_total < 0 or p_score > p_total then
    raise exception 'Pontuação inválida.';
  end if;
  if jsonb_typeof(coalesce(p_answers, '[]'::jsonb)) <> 'array' then
    raise exception 'Formato de respostas inválido.';
  end if;

  insert into public.neuroquiz_participants(full_name, score, total, answers)
  values (trim(p_name), p_score, p_total, coalesce(p_answers, '[]'::jsonb))
  returning id, access_token into v_id, v_token;

  return jsonb_build_object('participant_id', v_id, 'access_token', v_token);
end;
$$;

-- Resultados públicos: classificação + apenas respostas escritas de opinião.
-- Não devolve respostas de conhecimentos, nomes verdadeiros, email ou token.
create or replace function public.get_neuroquiz_public_results(
  p_participant_id uuid,
  p_access_token uuid
) returns table (
  display_name text,
  score integer,
  total integer,
  opinions jsonb,
  completed_at timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (
    select 1 from public.neuroquiz_participants p
    where p.id = p_participant_id and p.access_token = p_access_token
  ) then
    raise exception 'Acesso aos resultados não autorizado. Termina primeiro o quiz.';
  end if;

  return query
  select
    (select string_agg(left(w.word, 1) || repeat('•', greatest(char_length(w.word)-1, 2)), ' ')
       from regexp_split_to_table(trim(p.full_name), '\s+') as w(word)) as display_name,
    p.score,
    p.total,
    coalesce((
      select jsonb_agg(jsonb_build_object(
        'question', a.item->>'question',
        'answer', a.item->'answer',
        'type', a.item->>'type'
      ) order by (a.item->>'activity_index')::integer)
      from jsonb_array_elements(p.answers) as a(item)
      where a.item->>'category' = 'Opiniões'
        and a.item->>'type' in ('words', 'open', 'brainstorm')
    ), '[]'::jsonb) as opinions,
    p.completed_at
  from public.neuroquiz_participants p
  order by p.score desc, p.completed_at asc;
end;
$$;

-- Administração: só os utilizadores explicitamente inscritos em neuroquiz_admins.
create or replace function public.get_neuroquiz_admin_results()
returns table (
  id uuid,
  full_name text,
  score integer,
  total integer,
  answers jsonb,
  completed_at timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null or not exists (
    select 1 from public.neuroquiz_admins a where a.user_id = auth.uid()
  ) then
    raise exception 'Acesso reservado ao administrador.';
  end if;

  return query
  select p.id, p.full_name, p.score, p.total, p.answers, p.completed_at
  from public.neuroquiz_participants p
  order by p.completed_at desc;
end;
$$;

revoke all on function public.submit_neuroquiz_participation(text, integer, integer, jsonb) from public;
revoke all on function public.get_neuroquiz_public_results(uuid, uuid) from public;
revoke all on function public.get_neuroquiz_admin_results() from public;
grant execute on function public.submit_neuroquiz_participation(text, integer, integer, jsonb) to anon, authenticated;
grant execute on function public.get_neuroquiz_public_results(uuid, uuid) to anon, authenticated;
grant execute on function public.get_neuroquiz_admin_results() to authenticated;
