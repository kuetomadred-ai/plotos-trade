DROP POLICY IF EXISTS firm_read ON public.pf_firm;
CREATE POLICY firm_read ON public.pf_firm FOR SELECT TO authenticated USING (id = 'firm');