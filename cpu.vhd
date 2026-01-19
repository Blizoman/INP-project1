-- cpu.vhd: Simple 8-bit CPU (BrainFuck interpreter)
-- Copyright (C) 2025 Brno University of Technology,
-- Faculty of Information Technology
-- Author(s): Andrej Bliznak <xblizna00@stud.fit.vutbr.cz>
--
library ieee;
use ieee.std_logic_1164.all;
use ieee.std_logic_arith.all;
use ieee.std_logic_unsigned.all;

-- ----------------------------------------------------------------------------
--                        Entity declaration
-- ----------------------------------------------------------------------------
entity cpu is
 port (
   CLK   : in std_logic;  -- hodinovy signal
   RESET : in std_logic;  -- asynchronni reset procesoru
   EN    : in std_logic;  -- povoleni cinnosti procesoru
 
   -- synchronni pamet RAM
   DATA_ADDR  : out std_logic_vector(12 downto 0); -- adresa do pameti
   DATA_WDATA : out std_logic_vector(7 downto 0); -- mem[DATA_ADDR] <- DATA_WDATA pokud DATA_EN='1'
   DATA_RDATA : in std_logic_vector(7 downto 0);  -- DATA_RDATA <- ram[DATA_ADDR] pokud DATA_EN='1'
   DATA_RDWR  : out std_logic;                    -- cteni (1) / zapis (0)
   DATA_EN    : out std_logic;                    -- povoleni cinnosti
   
   -- vstupni port
   IN_DATA   : in std_logic_vector(7 downto 0);   -- IN_DATA <- stav klavesnice pokud IN_VLD='1' a IN_REQ='1'
   IN_VLD    : in std_logic;                      -- data platna
   IN_REQ    : out std_logic;                     -- pozadavek na vstup data
   
   -- vystupni port
   OUT_DATA : out  std_logic_vector(7 downto 0);  -- zapisovana data
   OUT_BUSY : in std_logic;                       -- LCD je zaneprazdnen (1), nelze zapisovat
   OUT_INV  : out std_logic;                      -- pozadavek na aktivaci inverzniho zobrazeni (1)
   OUT_WE   : out std_logic;                      -- LCD <- OUT_DATA pokud OUT_WE='1' a OUT_BUSY='0'

   -- stavove signaly
   READY    : out std_logic;                      -- hodnota 1 znamena, ze byl procesor inicializovan a zacina vykonavat program
   DONE     : out std_logic                       -- hodnota 1 znamena, ze procesor ukoncil vykonavani programu (narazil na instrukci halt)
 );
end cpu;


-- ----------------------------------------------------------------------------
--                      Architecture declaration
-- ----------------------------------------------------------------------------
architecture behavioral of cpu is
-- pri tvorbe kodu reflektujte rady ze cviceni INP, zejmena mejte na pameti, ze 
--   - nelze z vice procesu ovladat stejny signal,
--   - je vhodne mit jeden proces pro popis jedne hardwarove komponenty, protoze pak
--      - u synchronnich komponent obsahuje sensitivity list pouze CLK a RESET a 
--      - u kombinacnich komponent obsahuje sensitivity list vsechny ctene signaly. 

    -- FSM (Konecny automat)
    type state_t is (
        STATE_SETUP,
        STATE_SEARCH,
        STATE_READY,
        STATE_FETCH_REQ,
        STATE_FETCH_WAIT,
        STATE_DECODE,

        STATE_EXECUTE_REQ,
        STATE_EXECUTE_READ_WAIT,
        STATE_EXECUTE_WRITE_READY,

        STATE_EXECUTE_DOT_REQ,
        STATE_EXECUTE_DOT_READY,

        STATE_EXECUTE_COMMA_REQ,
        STATE_EXECUTE_COMMA_WRITE,
        STATE_EXECUTE_COMMA_READY,

        STATE_WHILE_START,
        STATE_WHILE_SKIP_WAIT,
        STATE_WHILE_SKIP_CHECK,
        STATE_WHILE_END,
        STATE_WHILE_BACK_WAIT,
        STATE_WHILE_BACK_CHECK,

        STATE_DO_WHILE_END,
        STATE_DO_WHILE_BACK_WAIT,
        STATE_DO_WHILE_BACK_CHECK,

        STATE_NUMBERS_READY,
        STATE_DONE
    );

    signal state, next_state : state_t;
    
    -- Registry
    signal PC, PC_NEXT : std_logic_vector(12 downto 0);
    signal PTR, PTR_NEXT : std_logic_vector(12 downto 0);
    signal counter_while, counter_while_next : std_logic_vector(12 downto 0);
    signal counter_do_while, counter_do_while_next : std_logic_vector(12 downto 0);
    signal instr, instr_next : std_logic_vector(7 downto 0);

-- Main proc. (zatim :D)
begin

    -- Status signaly
    READY <= '0' when (state = STATE_SETUP) or (state = STATE_SEARCH) else '1';
    
    -- ------------------------------------------------------------------------
    -- 1. PROCES: preklapa registre na clk
    -- ------------------------------------------------------------------------
    process (CLK, RESET)
    begin
        if RESET = '1' then
            state            <= STATE_SETUP;
            PC               <= (others => '0');
            PTR              <= (others => '0');
            counter_while    <= (others => '0');
            counter_do_while <= (others => '0');
            instr            <= (others => '0');
        elsif rising_edge(CLK) then
            if EN = '1' then
                state            <= next_state;
                PC               <= PC_NEXT;
                PTR              <= PTR_NEXT;
                counter_while    <= counter_while_next;
                counter_do_while <= counter_do_while_next;
                instr            <= instr_next;
            end if;
        end if;
    end process;

    -- ------------------------------------------------------------------------
    -- 2. PROCES: LOGIKA AUTOMATU (Kombinacny) riesi logiku a dalsi stav
    -- ------------------------------------------------------------------------
    process (state, DATA_RDATA, IN_VLD, IN_DATA, OUT_BUSY, PC, PTR, counter_while, counter_do_while, instr)
    begin
        -- DEFAULTNE VALS
        next_state            <= state;             --pouzivam metodu "nexts" pre zamedzeniu
        PC_NEXT               <= PC;                -- okamzitej zmeny hodnoty, takto kazdy nabeznu hranu
        PTR_NEXT              <= PTR;               -- PC/counter/ptr nadobudne hodnotu svojho next
        counter_while_next    <= counter_while;     -- ktoru sme predtym nastavili
        counter_do_while_next <= counter_do_while;
        instr_next            <= instr; 

        -- Default vystupy
        DATA_ADDR  <= (others => '0');
        DATA_WDATA <= (others => '0');
        DATA_RDWR  <= '1'; -- 1 = read
        DATA_EN    <= '0';
        OUT_DATA   <= (others => '0');
        OUT_WE     <= '0';
        OUT_INV    <= '0';
        IN_REQ     <= '0';
        DONE       <= '0';
-----------------------------------------------------------
        case state is   -- hladanie startu @
            when STATE_SETUP =>
                DATA_ADDR <= PTR;
                DATA_EN   <= '1';
                next_state <= STATE_SEARCH;
-----------------------------------------------------------
            when STATE_SEARCH =>
                PTR_NEXT <= PTR + 1; 
                if (DATA_RDATA = x"40") then -- @
                    next_state <= STATE_READY;
                else
                    next_state <= STATE_SETUP; 
                end if;
-----------------------------------------------------------
            when STATE_READY =>
                if (EN = '1') then
                    next_state <= STATE_FETCH_REQ;
                else
                    next_state <= STATE_READY;
                end if;
-----------------------------------------------------------
            when STATE_FETCH_REQ => -- nacitanie instrukcie
                DATA_ADDR <= PC;
                DATA_RDWR <= '1';
                DATA_EN   <= '1';
                next_state <= STATE_FETCH_WAIT;
-----------------------------------------------------------
            when STATE_FETCH_WAIT =>
                next_state <= STATE_DECODE;
-----------------------------------------------------------
--///////////////////////////////////////////////////////-- DECODE state (krizovatka)
-----------------------------------------------------------
            when STATE_DECODE =>
                case DATA_RDATA is
                    when x"3E" => -- >                -- posun pointera
                        if PTR = "1111111111111" then -- Modulovanie (zachovanie kruhovosti)
                            PTR_NEXT <= (others => '0');
                        else
                            PTR_NEXT <= PTR + 1;
                        end if;
                        PC_NEXT <= PC + 1;
                        next_state <= STATE_FETCH_REQ;
-----------------------------------------------------------                    
                    when x"3C" => -- <                   -- posun pointera
                        if PTR = "0000000000000" then 
                            PTR_NEXT <= "1111111111111"; -- Modulovanie (zachovanie kruhovosti)
                        else
                            PTR_NEXT <= PTR - 1;
                        end if;
                        PC_NEXT <= PC + 1;
                        next_state <= STATE_FETCH_REQ;
----------------------------------------------------------- 
                    when x"2B" => -- +                  -- inc/dec hodnoty
                        instr_next <= x"2B"; 
                        next_state <= STATE_EXECUTE_REQ;
-----------------------------------------------------------                        
                    when x"2D" => -- -                  -- inc/dec hodnoty
                        instr_next <= x"2D";
                        next_state <= STATE_EXECUTE_REQ;
----------------------------------------------------------- 
                    when x"5B" => -- [                  -- while cyklus
                        DATA_ADDR <= PTR;
                        DATA_RDWR <= '1';
                        DATA_EN   <= '1';
                        PC_NEXT   <= PC + 1;
                        next_state <= STATE_WHILE_START;
----------------------------------------------------------- 
                    when x"5D" => -- ]                  -- while cyklus
                        DATA_ADDR <= PTR;
                        DATA_RDWR <= '1';
                        DATA_EN   <= '1';
                        next_state <= STATE_WHILE_END;
----------------------------------------------------------- 
                    when x"28" => -- (                  -- do-while cyklus
                        PC_NEXT <= PC + 1;  
                        next_state <= STATE_FETCH_REQ;
----------------------------------------------------------- 
                    when x"29" => -- )                  -- do-while cyklus
                        DATA_ADDR <= PTR;
                        DATA_RDWR <= '1';
                        DATA_EN   <= '1';
                        next_state <= STATE_DO_WHILE_END;
----------------------------------------------------------- 
                    when x"2E" => -- .                  -- vypis 
                        instr_next <= x"2E";
                        next_state <= STATE_EXECUTE_DOT_REQ;
----------------------------------------------------------- 
                    when x"2C" => -- ,                  -- vstup
                        instr_next <= x"2C";
                        next_state <= STATE_EXECUTE_COMMA_REQ;
----------------------------------------------------------- 
                    when x"30" | x"31" | x"32" | x"33" | x"34" | x"35" | x"36" | x"37" | 
                         x"38" | x"39" | x"41" | x"42" | x"43" | x"44" | x"45" | x"46" =>
                        -- ASCII '0'..'9' + 'A' .. 'F'  -- ukladanie hex hodnot
                        DATA_ADDR <= PTR;
                        DATA_RDWR <= '0'; -- Zapis
                        DATA_EN   <= '1';
                        
                        -- Obycajny switch case 
                        case DATA_RDATA is
                            when x"30" => DATA_WDATA <= x"00";
                            when x"31" => DATA_WDATA <= x"10";
                            when x"32" => DATA_WDATA <= x"20";
                            when x"33" => DATA_WDATA <= x"30";
                            when x"34" => DATA_WDATA <= x"40";
                            when x"35" => DATA_WDATA <= x"50";
                            when x"36" => DATA_WDATA <= x"60";
                            when x"37" => DATA_WDATA <= x"70";
                            when x"38" => DATA_WDATA <= x"80";
                            when x"39" => DATA_WDATA <= x"90";
                            when x"41" => DATA_WDATA <= x"A0";
                            when x"42" => DATA_WDATA <= x"B0";
                            when x"43" => DATA_WDATA <= x"C0";
                            when x"44" => DATA_WDATA <= x"D0";
                            when x"45" => DATA_WDATA <= x"E0";
                            when x"46" => DATA_WDATA <= x"F0";
                            when others => DATA_WDATA <= x"00";
                        end case;
                        
                        PC_NEXT <= PC + 1;
                        next_state <= STATE_NUMBERS_READY;
-----------------------------------------------------------
                    when x"40" => -- '@' pre zavinac ideme do DONE pre ukoncenie vyrazu -- mam
                        next_state <= STATE_DONE;
-----------------------------------------------------------
                    when others => 
                        PC_NEXT <= PC + 1;
                        next_state <= STATE_FETCH_REQ;
                end case;
-----------------------------------------------------------
            when STATE_NUMBERS_READY =>
                next_state <= STATE_FETCH_REQ;
-----------------------------------------------------------
            when STATE_EXECUTE_REQ =>
                DATA_ADDR <= PTR;
                DATA_RDWR <= '1';
                DATA_EN   <= '1';
                next_state <= STATE_EXECUTE_READ_WAIT;
-----------------------------------------------------------
            when STATE_EXECUTE_READ_WAIT =>
                DATA_ADDR <= PTR;
                DATA_RDWR <= '0'; -- Zapis
                DATA_EN   <= '1';
                if instr = x"2B" then
                    DATA_WDATA <= DATA_RDATA + 1;
                elsif instr = x"2D" then
                    DATA_WDATA <= DATA_RDATA - 1;
                end if;
                next_state <= STATE_EXECUTE_WRITE_READY;
-----------------------------------------------------------
            when STATE_EXECUTE_WRITE_READY =>
                PC_NEXT <= PC + 1;
                next_state <= STATE_FETCH_REQ;
-----------------------------------------------------------
            when STATE_EXECUTE_DOT_REQ =>
                DATA_ADDR <= PTR;
                DATA_RDWR <= '1';
                DATA_EN   <= '1';
                if OUT_BUSY = '0' then
                    next_state <= STATE_EXECUTE_DOT_READY;
                else
                    next_state <= STATE_EXECUTE_DOT_REQ;
                end if;
-----------------------------------------------------------
            when STATE_EXECUTE_DOT_READY =>
                OUT_WE <= '1';
                OUT_DATA <= DATA_RDATA;
                PC_NEXT <= PC + 1;
                next_state <= STATE_FETCH_REQ;
-----------------------------------------------------------
            when STATE_EXECUTE_COMMA_REQ =>
                IN_REQ <= '1';
                if IN_VLD = '1' then
                    next_state <= STATE_EXECUTE_COMMA_WRITE;
                else
                    next_state <= STATE_EXECUTE_COMMA_REQ;
                end if;
-----------------------------------------------------------
            when STATE_EXECUTE_COMMA_WRITE =>
                DATA_ADDR <= PTR;
                DATA_RDWR <= '0';
                DATA_EN   <= '1';
                DATA_WDATA <= IN_DATA;
                next_state <= STATE_EXECUTE_COMMA_READY;
-----------------------------------------------------------
            when STATE_EXECUTE_COMMA_READY =>
                PC_NEXT <= PC + 1;
                next_state <= STATE_FETCH_REQ;
-----------------------------------------------------------
            when STATE_WHILE_START =>                   -- zaciatok while, ak je nula, skocime na koniec
                if DATA_RDATA = x"00" then
                    counter_while_next <= "0000000000001";
                    next_state <= STATE_WHILE_SKIP_WAIT;
                else
                    next_state <= STATE_FETCH_REQ;
                end if;
-----------------------------------------------------------
            when STATE_WHILE_SKIP_WAIT =>
                if counter_while = "0000000000000" then
                    next_state <= STATE_FETCH_REQ;
                else
                    DATA_ADDR <= PC;
                    DATA_RDWR <= '1';
                    DATA_EN   <= '1';
                    next_state <= STATE_WHILE_SKIP_CHECK;
                end if;
-----------------------------------------------------------
            when STATE_WHILE_SKIP_CHECK =>              -- preskakovanie vnutra cyklu, riesi vnorene zatvorky
                PC_NEXT <= PC + 1;
                if DATA_RDATA = x"5B" then -- [
                    counter_while_next <= counter_while + 1;
                elsif DATA_RDATA = x"5D" then -- ]
                    counter_while_next <= counter_while - 1;
                end if;
                next_state <= STATE_WHILE_SKIP_WAIT;
-----------------------------------------------------------
            when STATE_WHILE_END =>                     -- koniec while, ak nie je nula, vraciame sa na zaciatok
                if DATA_RDATA = x"00" then
                    PC_NEXT <= PC + 1;
                    next_state <= STATE_FETCH_REQ;
                else
                    counter_while_next <= "0000000000001";
                    PC_NEXT <= PC - 1;
                    next_state <= STATE_WHILE_BACK_WAIT;
                end if;
-----------------------------------------------------------
            when STATE_WHILE_BACK_WAIT =>
                if counter_while = "0000000000000" then
                    PC_NEXT <= PC + 1;
                    next_state <= STATE_FETCH_REQ;
                else
                    DATA_ADDR <= PC;
                    DATA_RDWR <= '1';
                    DATA_EN   <= '1';
                    next_state <= STATE_WHILE_BACK_CHECK;
                end if;
-----------------------------------------------------------
            when STATE_WHILE_BACK_CHECK =>              -- hladanie parovej [ smerom dozadu
                if DATA_RDATA = x"5D" then -- ]
                    counter_while_next <= counter_while + 1;
                elsif DATA_RDATA = x"5B" then -- [
                    counter_while_next <= counter_while - 1;
                end if;
                
                if PC = "0000000000000" then
                   next_state <= STATE_FETCH_REQ; 
                else
                   PC_NEXT <= PC - 1;
                   next_state <= STATE_WHILE_BACK_WAIT;
                end if;
-----------------------------------------------------------
            when STATE_DO_WHILE_END =>                  -- koniec do-while, kontrola podmienky pre opakovanie
                if DATA_RDATA = x"00" then
                    PC_NEXT <= PC + 1;
                    next_state <= STATE_FETCH_REQ;
                else
                    counter_do_while_next <= "0000000000001";
                    PC_NEXT <= PC - 1;
                    next_state <= STATE_DO_WHILE_BACK_WAIT;
                end if;
-----------------------------------------------------------
            when STATE_DO_WHILE_BACK_WAIT =>
                if counter_do_while = "0000000000000" then
                    PC_NEXT <= PC + 1;
                    next_state <= STATE_FETCH_REQ;
                else
                    DATA_ADDR <= PC;
                    DATA_RDWR <= '1';
                    DATA_EN   <= '1';
                    next_state <= STATE_DO_WHILE_BACK_CHECK;
                end if;
-----------------------------------------------------------
            when STATE_DO_WHILE_BACK_CHECK =>           -- navrat na zaciatok do-while cyklu (
                if DATA_RDATA = x"29" then -- )
                    counter_do_while_next <= counter_do_while + 1;
                elsif DATA_RDATA = x"28" then -- (
                    counter_do_while_next <= counter_do_while - 1;
                end if;

                if PC = "0000000000000" then
                    next_state <= STATE_FETCH_REQ;
                else
                    PC_NEXT <= PC - 1;
                    next_state <= STATE_DO_WHILE_BACK_WAIT;
                end if;
-----------------------------------------------------------
            when STATE_DONE =>
                DONE <= '1';
                next_state <= STATE_DONE;
-----------------------------------------------------------
            when others =>
                next_state <= STATE_SETUP;
-----------------------------------------------------------
        end case;
    end process;

end behavioral;