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

        const { table_id, sales_order_id, payment_status } = await req.json()

        if (payment_status === undefined) {
            throw new Error('payment_status is required');
        }

        let query = supabase.from('sales_order').update({ payment_status });

        if (sales_order_id) {
            query = query.eq('sales_order_id', sales_order_id);
        } else if (table_id) {
            // If only table_id is provided, update the active order (status 0 OR 1)
            // But we must be careful not to update paid orders.
            // We want to toggle between 0 and 1.
            query = query.eq('table_id', table_id).in('payment_status', [0, 1]);
        } else {
             throw new Error('Either table_id or sales_order_id is required');
        }

        const { data, error } = await query.select();

        if (error) throw error;

        return new Response(
            JSON.stringify({ success: true, data }),
            {
                headers: { ...corsHeaders, 'Content-Type': 'application/json' },
                status: 200,
            }
        )

    } catch (error) {
        return new Response(
            JSON.stringify({ error: error.message }),
            {
                headers: { ...corsHeaders, 'Content-Type': 'application/json' },
                status: 400,
            }
        )
    }
})
