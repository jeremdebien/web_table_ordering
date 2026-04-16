import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

serve(async (req) => {
    if (req.method === 'OPTIONS') {
        return new Response('ok', { headers: corsHeaders })
    }

    try {
        const supabase = createClient(
            Deno.env.get('SUPABASE_URL') ?? '',
            Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
        )

        const { action, device_id, nickname } = await req.json()

        if (!device_id) {
            throw new Error('device_id is required');
        }

        if (action === 'get') {
            const { data, error } = await supabase
                .from('customers')
                .select('nickname')
                .eq('device_id', device_id)
                .maybeSingle()

            if (error) throw error
            return new Response(
                JSON.stringify({ nickname: data?.nickname || null }),
                { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 200 }
            )
        } 
        
        if (action === 'upsert') {
            if (!nickname) {
                throw new Error('nickname is required for upsert');
            }

            const { error } = await supabase
                .from('customers')
                .upsert({
                    device_id,
                    nickname,
                    updated_at: new Date().toISOString()
                }, { onConflict: 'device_id' })

            if (error) throw error
            return new Response(
                JSON.stringify({ success: true }),
                { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 200 }
            )
        }

        throw new Error('Invalid action');

    } catch (error) {
        return new Response(
            JSON.stringify({ error: error.message }),
            { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 400 }
        )
    }
})
