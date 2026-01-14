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

        const { table_id, branch_id, guest_count, items } = await req.json()

        if (!table_id) {
            throw new Error('table_id is required');
        }

        // Check for existing active order (payment_status = 0)
        let { data: existingOrder, error: fetchError } = await supabase
            .from('sales_order')
            .select('sales_order_id, guest_count')
            .eq('table_id', table_id)
            .eq('payment_status', 0)
            .maybeSingle()

        if (fetchError) throw fetchError

        let salesOrderId;

        if (existingOrder) {
            salesOrderId = existingOrder.sales_order_id;
        } else {
            // Get next sales_order_id for the branch
            const { data: maxOrder, error: maxError } = await supabase
                .from('sales_order')
                .select('sales_order_id')
                .eq('branch_id', branch_id)
                .order('sales_order_id', { ascending: false })
                .limit(1)
                .maybeSingle()

            if (maxError) throw maxError

            const nextSalesOrderId = (maxOrder?.sales_order_id || 0) + 1

            // Create new order
            const { data: newOrder, error: createError } = await supabase
                .from('sales_order')
                .insert({
                    table_id,
                    branch_id,
                    sales_order_id: nextSalesOrderId,
                    guest_count: guest_count || 1,
                    eligible_guest_count: 0,
                    order_type: 0, // Default to Dine-in
                    payment_status: 0,
                    created_at: new Date().toISOString(),
                })
                .select('sales_order_id')
                .single()

            if (createError) throw createError
            salesOrderId = newOrder.sales_order_id
        }

        // Prepare items for insertion
        if (items && items.length > 0) {
            // Get next order_item_id start value for the branch
            const { data: maxItem, error: maxItemError } = await supabase
                .from('sales_order_item')
                .select('order_item_id')
                .eq('branch_id', branch_id)
                .order('order_item_id', { ascending: false })
                .limit(1)
                .maybeSingle()

            if (maxItemError) throw maxItemError

            let currentOrderItemId = (maxItem?.order_item_id || 0);

            const orderItems = items.map((item: any) => {
                currentOrderItemId++;
                return {
                    sales_order_id: salesOrderId,
                    branch_id,
                    order_item_id: currentOrderItemId,
                    item_barcode: item.item_barcode,
                    quantity: item.quantity,
                    amount: item.amount,
                    item_modifiers: item.item_modifiers,
                    is_disc_exempt: item.is_disc_exempt || false,
                    item_discount: item.item_discount || 0,
                    posting_date: new Date().toISOString()
                };
            });

            const { error: insertItemsError } = await supabase
                .from('sales_order_item')
                .insert(orderItems)

            if (insertItemsError) throw insertItemsError
        }

        return new Response(
            JSON.stringify({ success: true, sales_order_id: salesOrderId }),
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
