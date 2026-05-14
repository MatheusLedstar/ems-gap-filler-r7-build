package br.com.ledstar.ems.gapfiller;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.scheduling.annotation.EnableScheduling;
import net.javacrumbs.shedlock.spring.annotation.EnableSchedulerLock;

@SpringBootApplication
@EnableScheduling
@EnableSchedulerLock(defaultLockAtMostFor = "PT30M")
public class GapFillerApplication {
    public static void main(String[] args) {
        SpringApplication.run(GapFillerApplication.class, args);
    }
}
