// Edge Function: notificar-trocas
// Roda 1x por dia (agendada via Supabase Cron) e envia Web Push
// pra donos de carros com troca próxima ou atrasada.
//
// Deploy: supabase functions deploy notificar-trocas
// Agendar: supabase functions schedule notificar-trocas --cron "0 12 * * *"
// (todo dia às 12:00 UTC — ajuste o fuso como preferir)
//
// Secrets necessários (supabase secrets set):
//   VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY, VAPID_SUBJECT (ex: mailto:voce@seudominio.com)
//   SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY (já vêm automáticos no ambiente da function)

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import webpush from 'https://esm.sh/web-push@3.6.7';

const supabase = createClient(
  Deno.env.get('SUPABASE_URL')!,
  Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
);

webpush.setVapidDetails(
  Deno.env.get('VAPID_SUBJECT')!,
  Deno.env.get('VAPID_PUBLIC_KEY')!,
  Deno.env.get('VAPID_PRIVATE_KEY')!
);

Deno.serve(async () => {
  const { data: cars, error } = await supabase.from('my_cars').select('*');
  if (error) return new Response(JSON.stringify({ error: error.message }), { status: 500 });

  let sent = 0;
  for (const car of cars ?? []) {
    if (car.status !== 'proxima' && car.status !== 'atrasada') continue;

    // evita reenviar notificação do mesmo tipo pro mesmo carro no mesmo dia
    const { data: already } = await supabase
      .from('notification_log')
      .select('id')
      .eq('car_id', car.id)
      .eq('kind', car.status)
      .gte('sent_at', new Date(Date.now() - 20 * 3600 * 1000).toISOString());
    if (already && already.length > 0) continue;

    const { data: subs } = await supabase
      .from('push_subscriptions')
      .select('*')
      .eq('user_id', car.owner_id);

    const title = car.status === 'atrasada' ? 'Troca de óleo atrasada' : 'Troca de óleo se aproximando';
    const body = `${car.nickname}: KM atual ${car.current_km}, próxima troca em ${car.next_change_km} km.`;

    for (const sub of subs ?? []) {
      try {
        await webpush.sendNotification(
          { endpoint: sub.endpoint, keys: { p256dh: sub.p256dh, auth: sub.auth } },
          JSON.stringify({ title, body, url: `./index.html` })
        );
        sent++;
      } catch (e) {
        console.error('push falhou', sub.endpoint, e.message);
        // se a inscrição expirou (410/404), remove do banco
        if (e.statusCode === 410 || e.statusCode === 404) {
          await supabase.from('push_subscriptions').delete().eq('id', sub.id);
        }
      }
    }

    await supabase.from('notification_log').insert({ car_id: car.id, kind: car.status });
  }

  return new Response(JSON.stringify({ ok: true, sent }), { headers: { 'Content-Type': 'application/json' } });
});
